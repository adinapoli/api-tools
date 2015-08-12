{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE OverlappingInstances       #-}
{-# OPTIONS_GHC -fno-warn-orphans       #-}

module Data.API.Tools.CBOR
    ( cborTool'
    ) where

import           Data.API.TH
import           Data.API.Tools.Combinators
import           Data.API.Tools.Datatypes
import           Data.API.Tools.Enum
import           Data.API.Types
import           Data.API.Utils
import           Data.Time.Clock

import           Control.Applicative
import           Data.Binary.Serialise.CBOR.Class
import           Data.Binary.Serialise.CBOR.Decoding
import           Data.Binary.Serialise.CBOR.Encoding
import           Data.List (foldl')
import           Data.Maybe
import qualified Data.Map                       as Map
import           Data.Monoid
import qualified Data.Text                      as T
import           Language.Haskell.TH

class ToCBOR a where
    toCBOR  :: a -> Encoding

class FromCBOR a where
    fromCBOR :: Decoder a

instance (ToCBOR a, FromCBOR a) => Serialise a where
    encode = toCBOR
    decode = fromCBOR

instance ToCBOR UTCTime where
    toCBOR = undefined  -- TODO on the binary-CBOR side

instance FromCBOR UTCTime where
    fromCBOR = undefined  -- TODO on the binary-CBOR side

instance ToCBOR Binary where
    toCBOR = undefined  -- TODO on the binary-CBOR side

instance FromCBOR Binary where
    fromCBOR = undefined  -- TODO on the binary-CBOR side

-- | Tool to generate 'ToCBOR' and 'FromCBOR
-- instances for types generated by 'datatypesTool'. This depends on
-- 'enumTool'.
cborTool' :: APITool
cborTool' = apiNodeTool $ toJsonNodeTool <> fromJsonNodeTool


-- | Tool to generate 'ToCBOR' instance for an API node
toJsonNodeTool :: APINodeTool
toJsonNodeTool = apiSpecTool gen_sn_to gen_sr_to gen_su_to gen_se_to mempty
-- not essential and conflits with JSON tests: <> gen_pr

-- | Tool to generate 'FromCBOR' instance for an API node
fromJsonNodeTool :: APINodeTool
fromJsonNodeTool = apiSpecTool gen_sn_fm gen_sr_fm gen_su_fm gen_se_fm mempty
-- not essential and conflits with JSON tests: <> gen_in


{-
instance ToCBOR JobId where
    toCBOR = encodeString . _JobId
-}

gen_sn_to :: Tool (APINode, SpecNewtype)
gen_sn_to = mkTool $ \ ts (an, sn) -> optionalInstanceD ts ''ToCBOR [nodeRepT an]
                                          [simpleD 'toCBOR (bdy an sn)]
  where
    bdy an sn = [e| $(ine sn) . $(newtypeProjectionE an) |]

    ine sn = case snType sn of
            BTstring -> [e| encodeString |]
            BTbinary -> [e| encodeBytes |]
            BTbool   -> [e| encodeBool |]
            BTint    -> [e| encodeInt |]
            BTutc    -> [e| encodeString . mkUTC' |]


{-
instance FromCBOR JobId where
    fromCBOR = JobId <$> decodeString

In this version we don't check the @snFilter@, for simplicity and speed.
This is safe, since the CBOR code is used only internally as a data
representation format, not as a communication format with clients
that could potentially send faulty data.
-}

gen_sn_fm :: Tool (APINode, SpecNewtype)
gen_sn_fm = mkTool $ \ ts (an, sn) -> optionalInstanceD ts ''FromCBOR [nodeRepT an]
                                          [simpleD 'fromCBOR (bdy ts an sn)]
  where
    bdy ts an sn = [e| $(nodeNewtypeConE ts an sn) <$> $(oute sn) |]

    oute sn =
        case snType sn of
            BTstring -> [e| decodeString |]
            BTbinary -> [e| decodeBytes |]
            BTbool   -> [e| decodeBool |]
            BTint    -> [e| decodeInt |]
            BTutc    -> [e| fromMaybe (error "Can't parse UTC from CBOR")
                            . parseUTC'
                            <$> decodeString |]


{-
instance ToCBOR JobSpecId where
     toCBOR = \ x ->
        encodeRecord
            [ "Id"         .= jsiId         x
            , "Input"      .= jsiInput      x
            , "Output"     .= jsiOutput     x
            , "PipelineId" .= jsiPipelineId x
            ]

We assume the order of record fields give by srFields is fixed.
If the order in the definition is changed, the encoding differs
and so the data has to be migrated.
-}

gen_sr_to :: Tool (APINode, SpecRecord)
gen_sr_to = mkTool $ \ ts (an, sr) -> do
    x <- newName "x"
    optionalInstanceD ts ''ToCBOR [nodeRepT an] [simpleD 'toCBOR (bdy an sr x)]
  where
    bdy an sr x = lamE [varP x] $
            varE 'encodeRecord `appE`
            listE [ [e| encodeString $(fieldNameE fn)
                        <> encode ($(nodeFieldE an fn) $(varE x)) |]
                  | (fn, _) <- srFields sr ]

-- TODO: lots of thunks; perhaps calculate @length sr@ first
-- TODO: I assume encodeBreak is a noop
encodeRecord :: [Encoding] -> Encoding
encodeRecord l = encodeMapLen (fromIntegral $ length l)
                 <> foldl' (<>) encodeBreak l


{-
instance FromCBOR JobSpecId where
     fromCBOR (Object v) =
        JobSpecId <$>
            v .: "Id"                               <*>
            v .: "Input"                            <*>
            v .: "Output"                           <*>
            v .: "PipelineId"
-}

gen_sr_fm :: Tool (APINode, SpecRecord)
gen_sr_fm = mkTool $ \ ts (an, sr) -> do
    optionalInstanceD ts ''FromCBOR [nodeRepT an]
                      [simpleD 'fromCBOR (cl an sr)]
  where
    cl an sr    = varE '(>>)
                    `appE` (varE 'decodeMapLen)  --TODO: check len with srFields
                    `appE` bdy
      where
        bdy = applicativeE (nodeConE an) $ map project (srFields sr)
        project (_fn, ft) = [e| decodeString >> decode |]
          where _ro    = ftReadOnly ft  -- TODO: use as in withDefaultField
                _mb_dv = ftDefault ft  -- TODO: use as in withDefaultField
          -- TODO: check that $(fieldNameE fn) matches the decoded name
          -- and if not, use the default value, etc.


{-
instance ToCBOR Foo where
    toCBOR (Bar x) = object [ "x" .= x ]
    toCBOR (Baz x) = object [ "y" .= x ]
-}

gen_su_to :: Tool (APINode, SpecUnion)
gen_su_to = mkTool $ \ ts (an, su) -> optionalInstanceD ts ''ToCBOR [nodeRepT an] [funD 'toCBOR (cls an su)]
  where
    cls an su = map (cl an . fst) (suFields su)

    cl an fn = do x <- newName "x"
                  clause [nodeAltConP an fn [varP x]] (bdy fn x) []

    bdy fn x = normalB [e| encodeRecord [ encodeString $(fieldNameE fn)
                                          <> encode $(varE x) ] |]


{-
instance FromCBOR Foo where
    fromCBOR = decodeUnion [ ("x", fmap Bar . fromCBOR)
                           , ("y", fmap Baz . fromCBOR) ]
-}

gen_su_fm :: Tool (APINode, SpecUnion)
gen_su_fm = mkTool $ \ ts (an, su) ->
    optionalInstanceD ts ''FromCBOR [nodeRepT an]
                      [simpleD 'fromCBOR (bdy an su)]
 where
    bdy an su = varE 'decodeUnion `appE` listE (map (alt an) (suFields su))

    alt an (fn, _) = [e| ( $(fieldNameE fn) , fmap $(nodeAltConE an fn) decode ) |]

decodeUnion :: [(T.Text, Decoder a)] -> Decoder a
decodeUnion ds = do
    dfn <- decodeString
    case lookup dfn ds of
      Nothing -> error "Unexpected field in union in CBOR"
      Just d -> d

{-
instance ToCBOR FrameRate where
    toCBOR    = encodeString . _text_FrameRate
-}

gen_se_to :: Tool (APINode, SpecEnum)
gen_se_to = mkTool $ \ ts (an, _se) -> optionalInstanceD ts ''ToCBOR [nodeRepT an] [simpleD 'toCBOR (bdy an)]
  where
    bdy an = [e| encodeString . $(varE (text_enum_nm an)) |]


{-
instance FromCBOR FrameRate where
    fromCBOR = cborStrMap_p _map_FrameRate <$> decodeString
-}

gen_se_fm :: Tool (APINode, SpecEnum)
gen_se_fm = mkTool $ \ ts (an, _se) -> optionalInstanceD ts ''FromCBOR [nodeRepT an]
                                           [simpleD 'fromCBOR (bdy an)]
  where
    bdy an = [e| cborStrMap_p $(varE (map_enum_nm an)) <$> decodeString |]


cborStrMap_p :: Ord a => Map.Map T.Text a -> T.Text -> a
cborStrMap_p mp t = fromMaybe (error "Unexpected enumeration key in CBOR")
                    $ flip Map.lookup mp t


gen_in :: Tool APINode
gen_in = mkTool $ \ ts an -> case anConvert an of
  Nothing          -> return []
  Just (inj_fn, _) -> optionalInstanceD ts ''FromCBOR [nodeT an]
                          [simpleD 'fromCBOR bdy]
   where
    bdy = do x <- newName "x"
             lamE [varP x] [e| fromCBOR $(varE x) >>= $inj |]
    inj = varE $ mkName $ _FieldName inj_fn


gen_pr :: Tool APINode
gen_pr = mkTool $ \ ts an -> case anConvert an of
  Nothing          -> return []
  Just (_, prj_fn) -> optionalInstanceD ts ''ToCBOR [nodeT an] [simpleD 'toCBOR bdy]
   where
    bdy = [e| toCBOR . $prj |]
    prj = varE $ mkName $ _FieldName prj_fn


fieldNameE :: FieldName -> ExpQ
fieldNameE = stringE . _FieldName
