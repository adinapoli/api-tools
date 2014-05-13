{-# LANGUAGE TemplateHaskell            #-}

module Data.API.Tools.JSON
    ( jsonTool
    , toJsonNodeTool
    , fromJsonNodeTool
    ) where

import           Data.API.JSON
import           Data.API.TH
import           Data.API.Tools.Combinators
import           Data.API.Tools.Datatypes
import           Data.API.Tools.Enum
import           Data.API.Types
import           Data.API.Utils

import           Data.Aeson hiding (withText, withBool)
import           Control.Applicative
import qualified Data.HashMap.Strict            as HMap
import qualified Data.Map                       as Map
import           Data.Monoid
import qualified Data.Text                      as T
import           Language.Haskell.TH


-- | Tool to generate 'ToJSON' and 'FromJSONWithErrs' instances for
-- types generated by 'datatypesTool'.  This depends on 'enumTool'.
jsonTool :: APITool
jsonTool = apiNodeTool $ toJsonNodeTool <> fromJsonNodeTool


-- | Tool to generate 'ToJSON' instance for an API node
toJsonNodeTool :: APINodeTool
toJsonNodeTool = apiSpecTool gen_sn_to gen_sr_to gen_su_to gen_se_to mempty
                 <> gen_pr

-- | Tool to generate 'FromJSONWithErrs' instance for an API node
fromJsonNodeTool :: APINodeTool
fromJsonNodeTool = apiSpecTool gen_sn_fm gen_sr_fm gen_su_fm gen_se_fm mempty
                   <> gen_in


{-
instance ToJSON JobId where
    toJSON = String . _JobId
-}

gen_sn_to :: Tool (APINode, SpecNewtype)
gen_sn_to = mkTool $ \ ts (an, sn) -> optionalInstanceD ts ''ToJSON [nodeRepT an]
                                          [simpleD 'toJSON (bdy an sn)]
  where
    bdy an sn = [e| $(ine sn) . $(newtypeProjectionE an) |]

    ine sn = case snType sn of
            BTstring -> [e| String |]
            BTbinary -> [e| toJSON |]
            BTbool   -> [e| Bool   |]
            BTint    -> [e| mkInt  |]
            BTutc    -> [e| mkUTC  |]


{-
instance FromJSONWithErrs JobId where
    parseJSONWithErrs = withText "JobId" (pure . JobId)
-}

gen_sn_fm :: Tool (APINode, SpecNewtype)
gen_sn_fm = mkTool $ \ ts (an, sn) -> optionalInstanceD ts ''FromJSONWithErrs [nodeRepT an]
                                          [simpleD 'parseJSONWithErrs (bdy an sn)]
  where
    bdy an sn = [e| $(wth sn) $(typeNameE (anName an)) (pure . $(nodeConE an)) |]

    wth sn    =
        case (snType sn, snFilter sn) of
            (BTstring, Just (FtrStrg re)) -> [e| withRegEx re    |]
            (BTstring, _                ) -> [e| withText        |]
            (BTbinary, _                ) -> [e| withBinary      |]
            (BTbool  , _                ) -> [e| withBool        |]
            (BTint   , Just (FtrIntg ir)) -> [e| withIntRange ir |]
            (BTint   , _                ) -> [e| withInt         |]
            (BTutc   , Just (FtrUTC  ur)) -> [e| withUTCRange ur |]
            (BTutc   , _                ) -> [e| withUTC         |]



{-
instance ToJSON JobSpecId where
     toJSON = \ x ->
        object
            [ "Id"         .= jsiId         x
            , "Input"      .= jsiInput      x
            , "Output"     .= jsiOutput     x
            , "PipelineId" .= jsiPipelineId x
            ]
-}

gen_sr_to :: Tool (APINode, SpecRecord)
gen_sr_to = mkTool $ \ ts (an, sr) -> do
    x <- newName "x"
    optionalInstanceD ts ''ToJSON [nodeRepT an] [simpleD 'toJSON (bdy an sr x)]
  where
    bdy an sr x = lamE [varP x] $
            varE 'object `appE`
            listE [ [e| $(fieldNameE fn) .= $(nodeFieldE an fn) $(varE x) |]
                  | (fn, _) <- srFields sr ]


{-
instance FromJSONWithErrs JobSpecId where
     parseJSONWithErrs (Object v) =
        JobSpecId <$>
            v .: "Id"                               <*>
            v .: "Input"                            <*>
            v .: "Output"                           <*>
            v .: "PipelineId"
     parseJSONWithErrs Null       = parseJSONWithErrs (Object HMap.empty)
     parseJSONWithErrs v          = failWith $ expectedObject val
-}

gen_sr_fm :: Tool (APINode, SpecRecord)
gen_sr_fm = mkTool $ \ ts (an, sr) -> do
    x <- newName "x"
    optionalInstanceD ts ''FromJSONWithErrs [nodeRepT an]
                      [funD 'parseJSONWithErrs [cl an sr x, clNull, cl' x]]
  where
    cl an sr x  = clause [conP 'Object [varP x]] (normalB bdy) []
      where
        bdy = applicativeE (nodeConE an) $ map project (srFields sr)
        project (fn, ft) = [e| withDefaultField ro (fmap defaultValueAsJsValue mb_dv) $(fieldNameE fn) parseJSONWithErrs $(varE x) |]
          where ro    = ftReadOnly ft
                mb_dv = ftDefault ft

    clNull = clause [conP 'Null []] (normalB [e| parseJSONWithErrs (Object HMap.empty) |]) []

    cl'  x = clause [varP x] (normalB (bdy' x)) []
    bdy' x = [e| failWith (expectedObject $(varE x)) |]


{-
instance ToJSON Foo where
    toJSON (Bar x) = object [ "x" .= x ]
    toJSON (Baz x) = object [ "y" .= x ]
-}

gen_su_to :: Tool (APINode, SpecUnion)
gen_su_to = mkTool $ \ ts (an, su) -> optionalInstanceD ts ''ToJSON [nodeRepT an] [funD 'toJSON (cls an su)]
  where
    cls an su = map (cl an . fst) (suFields su)

    cl an fn = do x <- newName "x"
                  clause [nodeAltConP an fn [varP x]] (bdy fn x) []

    bdy fn x = normalB [e| object [ $(fieldNameE fn) .= $(varE x) ] |]


{-
instance FromJSONWithErrs Foo where
    parseJSONWithErrs (Object v) = alternatives (failWith $ MissingAlt ["x", "y"])
        [ Bar <$> v .:: "x"
        , Baz <$> v .:: "y"
        ]
    parseJSONWithErrs val        = failWith $ expectedObject val
-}

gen_su_fm :: Tool (APINode, SpecUnion)
gen_su_fm = mkTool $ \ ts (an, su) -> do
    x <- newName "x"
    optionalInstanceD ts ''FromJSONWithErrs [nodeRepT an]
                      [funD 'parseJSONWithErrs (cls an su x)]
 where
  cls an su x = [cl, cl']
   where
    cl  = clause [conP 'Object [varP x]] (normalB bdy) []
    bdy = [e| alternatives (failWith $ MissingAlt $ss) $alts |]

    alt fn = [e| fmap $(nodeAltConE an fn) ($(varE x) .:: $(fieldNameE fn)) |]

    alts = listE $ map alt fns
    ss   = listE $ map fieldNameE fns

    fns  = map fst $ suFields su

    cl'  = clause [varP x] (normalB bdy') []
    bdy' = [e| failWith (expectedObject $(varE x)) |]



{-
instance ToJSON FrameRate where
    toJSON    = String . _text_FrameRate
-}

gen_se_to :: Tool (APINode, SpecEnum)
gen_se_to = mkTool $ \ ts (an, _se) -> optionalInstanceD ts ''ToJSON [nodeRepT an] [simpleD 'toJSON (bdy an)]
  where
    bdy an = [e| String . $(varE (text_enum_nm an)) |]


{-
instance FromJSONWithErrs FrameRate where
    parseJSONWithErrs = jsonStrMap_p _map_FrameRate
-}

gen_se_fm :: Tool (APINode, SpecEnum)
gen_se_fm = mkTool $ \ ts (an, _se) -> optionalInstanceD ts ''FromJSONWithErrs [nodeRepT an]
                                           [simpleD 'parseJSONWithErrs (bdy an)]
  where
    bdy an = [e| jsonStrMap_p $(varE (map_enum_nm an)) |]


gen_in :: Tool APINode
gen_in = mkTool $ \ ts an -> case anConvert an of
  Nothing          -> return []
  Just (inj_fn, _) -> optionalInstanceD ts ''FromJSONWithErrs [nodeT an]
                          [simpleD 'parseJSONWithErrs bdy]
   where
    bdy = do x <- newName "x"
             lamE [varP x] [e| parseJSONWithErrs $(varE x) >>= $inj |]
    inj = varE $ mkName $ _FieldName inj_fn


gen_pr :: Tool APINode
gen_pr = mkTool $ \ ts an -> case anConvert an of
  Nothing          -> return []
  Just (_, prj_fn) -> optionalInstanceD ts ''ToJSON [nodeT an] [simpleD 'toJSON bdy]
   where
    bdy = [e| toJSON . $prj |]
    prj = varE $ mkName $ _FieldName prj_fn


alternatives :: Alternative t => t a -> [t a] -> t a
alternatives none = foldr (<|>) none

mkInt :: Int -> Value
mkInt = Number . fromInteger . toInteger


jsonStrMap_p :: Ord a => Map.Map T.Text a -> Value -> ParserWithErrs a
jsonStrMap_p mp = json_string_p (Map.keys mp) $ flip Map.lookup mp

json_string_p :: Ord a => [T.Text] -> (T.Text->Maybe a) -> Value -> ParserWithErrs a
json_string_p xs p (String t) | Just val <- p t = pure val
                              | otherwise       = failWith $ UnexpectedEnumVal xs t
json_string_p _  _ v                            = failWith $ expectedString v


fieldNameE :: FieldName -> ExpQ
fieldNameE = stringE . _FieldName

typeNameE :: TypeName -> ExpQ
typeNameE = stringE . _TypeName
