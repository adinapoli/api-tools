{-# LANGUAGE BangPatterns #-}
module Data.API.Value
    ( Value(..)
    , fromDefaultValue
    , parseJSON
    , encode
    , decode

      -- * QuickCheck test infrastructure
    , arbitrary
    , prop_jsonRoundTrip
    , prop_jsonGeneric
    , prop_cborRoundTrip
    , prop_cborGeneric
    ) where

import           Data.API.JSON
import           Data.API.NormalForm
import           Data.API.Types
import           Data.API.Utils

import           Control.Applicative
import           Control.DeepSeq
import qualified Data.Aeson                     as JS
import qualified Data.Binary.Serialise.CBOR          as CBOR
import qualified Data.Binary.Serialise.CBOR.Decoding as CBOR
import qualified Data.Binary.Serialise.CBOR.Encoding as CBOR
import           Data.Binary.Serialise.CBOR.Extra
import           Data.Binary.Serialise.CBOR.JSON
import qualified Data.Map.Strict                as Map
import           Data.Monoid
import qualified Data.Set                       as Set
import qualified Data.Text                      as T
import           Data.Traversable
import qualified Data.Vector                    as V
import qualified Test.QuickCheck                as QC
import qualified Test.QuickCheck.Property       as QCP
import           Prelude


data Value = String  !T.Text
           | UTCTime !T.Text
           | Bytes   !Binary
           | Bool    !Bool
           | Int     !Int
           | List    ![Value]
           | Maybe   !(Maybe Value)
           | Union   !FieldName !Value
           | Enum    !FieldName
           | Record  ![(FieldName, Value)]
           | JSON    !JS.Value
    deriving (Eq, Show)

instance NFData Value where
  rnf (String t)   = rnf t
  rnf (UTCTime t)  = rnf t
  rnf (Bytes b)    = rnf b
  rnf (Bool b)     = rnf b
  rnf (Int i)      = rnf i
  rnf (List xs)    = rnf xs
  rnf (Maybe mb)   = rnf mb
  rnf (Union fn v) = rnf fn `seq` rnf v
  rnf (Enum fn)    = rnf fn
  rnf (Record xs)  = rnf xs
  rnf (JSON v)     = rnf v

instance JS.ToJSON Value where
  toJSON v0 = case v0 of
                String t       -> JS.String t
                UTCTime t      -> JS.String t
                Bytes b        -> JS.toJSON b
                Bool b         -> JS.Bool b
                Int i          -> JS.toJSON i
                List vs        -> JS.toJSON vs
                Maybe Nothing  -> JS.Null
                Maybe (Just v) -> JS.toJSON v
                Union fn v     -> JS.object [_FieldName fn JS..= v]
                Enum fn        -> JS.String (_FieldName fn)
                Record xs      -> JS.object $ map (\ (fn, v) -> _FieldName fn JS..= v) xs
                JSON js        -> js


fromDefaultValue :: DefaultValue -> Value
fromDefaultValue dv = case dv of
    DefValList     -> List []
    DefValMaybe    -> Maybe Nothing
    DefValString s -> String s
    DefValBool   b -> Bool b
    DefValInt    n -> Int n
    DefValUtc    t -> UTCTime (mkUTC' t)


fromJSON :: NormAPI -> APIType -> JS.Value -> Either [(JSONError, Position)] (Value, [(JSONWarning, Position)])
fromJSON api ty v = runParserWithErrsTop defaultParseFlags (parseJSON api ty v)

parseJSON :: NormAPI -> APIType -> JS.Value -> ParserWithErrs Value
parseJSON api ty0 v = case ty0 of
    TyName tn  -> parseJSONDecl api tn (lookupTyName api tn) v
    TyList ty  -> case v of
                    JS.Array arr -> List <$> traverse (parseJSON api ty) (V.toList arr)
                    _            -> failWith (expectedArray v)
    TyMaybe ty -> case v of
                    JS.Null -> pure (Maybe Nothing)
                    _       -> Maybe . Just <$> parseJSON api ty v
    TyJSON     -> pure (JSON v)
    TyBasic bt -> parseJSONBasic bt v

parseJSONBasic :: BasicType -> JS.Value -> ParserWithErrs Value
parseJSONBasic bt = case bt of
    BTstring -> withText   "String"  (pure . String)
    BTbinary -> withBinary "Bytes"   (pure . Bytes)
    BTbool   -> withBool   "Bool"    (pure . Bool)
    BTint    -> withInt    "Int"     (pure . Int)
    BTutc    -> withText   "UTCTime" (pure . UTCTime)

parseJSONDecl :: NormAPI -> TypeName -> NormTypeDecl -> JS.Value -> ParserWithErrs Value
parseJSONDecl api tn d = case d of
    NRecordType nrt -> \ v -> case v of
                                JS.Object hm -> Record <$> traverse (parseField hm) (Map.toList nrt)
                                _            -> failWith (expectedObject v)
    NUnionType  nut -> withUnion (map (\ (fn, ty) -> (_FieldName fn, fmap (Union fn) . parseJSON api ty)) (Map.toList nut))
    NEnumType   net -> withText (T.unpack (_TypeName tn)) $ \ k ->
                           case lookupSet (FieldName k) net of
                             Just fn -> pure (Enum fn)
                             Nothing -> failWith (UnexpectedEnumVal (map _FieldName (Set.toList net)) k)
    NTypeSynonym ty -> parseJSON api ty
    NNewtype     bt -> parseJSONBasic bt
  where
    parseField hm (fn, ty) = (,) fn <$> withField (_FieldName fn) (parseJSON api ty) hm


encode :: Value -> CBOR.Encoding
encode v0 = case v0 of
    String t   -> CBOR.encodeString t
    UTCTime t  -> CBOR.encodeTag 0 <> CBOR.encodeString t
    Bytes b    -> CBOR.encode b
    Bool b     -> CBOR.encode b
    Int i      -> CBOR.encode i
    List vs    -> encodeListWith encode vs
    Maybe mb_v -> encodeMaybeWith encode mb_v
    Union fn v -> encodeUnion (_FieldName fn) (encode v)
    Enum fn    -> CBOR.encode (_FieldName fn)
    Record xs  -> CBOR.encodeMapLen (fromIntegral (length xs))
                  <> encodeRecordFields (map (\ (fn, v) -> CBOR.encode (_FieldName fn)
                                                           <> encode v) xs)
    JSON js    -> encodeJSON js


decode :: NormAPI -> APIType -> CBOR.Decoder Value
decode api ty0 = case ty0 of
    TyName tn  -> decodeDecl api (lookupTyName api tn)
    TyList ty  -> List <$> decodeListWith (decode api ty)
    TyMaybe ty -> Maybe <$> decodeMaybeWith (decode api ty)
    TyJSON     -> JSON <$> CBOR.decode
    TyBasic bt -> decodeBasic bt

decodeBasic :: BasicType -> CBOR.Decoder Value
decodeBasic bt = case bt of
    BTstring -> String <$> CBOR.decode
    BTbinary -> Bytes  <$> CBOR.decode
    BTbool   -> Bool   <$> CBOR.decode
    BTint    -> Int    <$> CBOR.decode
    BTutc    -> do _ <- CBOR.decodeTag
                   UTCTime <$> CBOR.decode

decodeDecl :: NormAPI -> NormTypeDecl -> CBOR.Decoder Value
decodeDecl api d = case d of
    NRecordType nrt -> do _ <- CBOR.decodeMapLen
                          Record <$> traverse decodeField (Map.toList nrt)
    NUnionType  nut -> do _ <- CBOR.decodeMapLen
                          k <- CBOR.decodeString
                          case lookupMap (FieldName k) nut of
                            Just (fn, ty) -> Union fn <$> decode api ty
                            Nothing       -> fail $ "unexpected union alternative: " ++ T.unpack k
    NEnumType   net -> do k <- CBOR.decodeString
                          case lookupSet (FieldName k) net of
                            Just fn -> pure (Enum fn)
                            Nothing -> fail $ "unexpected enum alternative: " ++ T.unpack k
    NTypeSynonym ty -> decode api ty
    NNewtype     bt -> decodeBasic bt
  where
    decodeField (fn, ty) = do _  <- CBOR.decodeString
                              !v <- decode api ty
                              return (fn, v)



arbitrary :: NormAPI -> QC.Gen (APIType, Value)
arbitrary api = do tn <- QC.elements (Map.keys api)
                   v  <- arbitraryOfType api (TyName tn)
                   return (TyName tn, v)

arbitraryOfType :: NormAPI -> APIType -> QC.Gen Value
arbitraryOfType api ty0 = case ty0 of
    TyName  tn -> arbitraryOfDecl api (lookupTyName api tn)
    TyList  ty -> List  <$> QC.listOf (arbitraryOfType api ty)
    TyMaybe ty -> Maybe <$> QC.oneof [pure Nothing, Just <$> arbitraryOfType api ty]
    TyJSON     -> JSON . JS.String <$> QC.arbitrary -- TODO
    TyBasic bt -> arbitraryOfBasicType bt

arbitraryOfBasicType :: BasicType -> QC.Gen Value
arbitraryOfBasicType bt = case bt of
    BTstring -> String  <$> QC.arbitrary
    BTbinary -> Bytes   <$> QC.arbitrary
    BTbool   -> Bool    <$> QC.arbitrary
    BTint    -> Int     <$> QC.arbitrary
    BTutc    -> UTCTime <$> QC.arbitrary -- TODO

arbitraryOfDecl :: NormAPI -> NormTypeDecl -> QC.Gen Value
arbitraryOfDecl api d = case d of
    NRecordType nrt -> Record <$> traverse (traverse (arbitraryOfType api)) (Map.toList nrt)
    NUnionType  nut -> do (fn, ty) <- QC.elements (Map.toList nut)
                          Union fn <$> arbitraryOfType api ty
    NEnumType   net -> Enum <$> QC.elements (Set.toList net)
    NTypeSynonym ty -> arbitraryOfType api ty
    NNewtype     bt -> arbitraryOfBasicType bt -- TODO: filters?


lookupTyName :: NormAPI -> TypeName -> NormTypeDecl
lookupTyName api tn = case Map.lookup tn api of
                        Just d  -> d
                        Nothing -> error $ "lookupTyName: missing declaration for "
                                               ++ T.unpack (_TypeName tn)

-- | QuickCheck property that converting a 'Value' to and from JSON
-- gives back the original value.
prop_jsonRoundTrip :: NormAPI -> QC.Property
prop_jsonRoundTrip api
  = QC.forAll (arbitrary api) $ \ (ty, v) ->
        case fromJSON api ty (JS.toJSON v) of
          Right (y, ws) | v /= y        -> QCP.failed { QCP.reason = "Expected " ++ show v
                                                                       ++ " but got " ++ show y }
                        | not (null ws) -> QCP.failed { QCP.reason = "Unexpected warnings: " ++ show ws }
                        | otherwise     -> QCP.succeeded
          Left err                      -> QCP.failed { QCP.reason = "Parse error: " ++ prettyJSONErrorPositions err }

-- | QuickCheck property that the type-specific JSON serialisation
-- agrees with deserialising as generic JSON and then serialising again
prop_jsonGeneric :: JS.ToJSON a => API -> TypeName -> a -> QCP.Result
prop_jsonGeneric api tn x = case fromJSON napi (TyName tn) js_v of
    Right (v, ws) | JS.toJSON v /= js_v -> QCP.failed { QCP.reason = "Expected " ++ show js_v
                                                                       ++ " but got " ++ show (JS.toJSON v) }
                  | not (null ws)       -> QCP.failed { QCP.reason = "Unexpected warnings: " ++ show ws }
                  | otherwise           -> QCP.succeeded
    Left err                            -> QCP.failed { QCP.reason = "Parse error: " ++ prettyJSONErrorPositions err }
  where
    napi = apiNormalForm api
    js_v = JS.toJSON x

prop_cborRoundTrip :: NormAPI -> QC.Property
prop_cborRoundTrip api
  = QC.forAll (arbitrary api) $ \ (ty, v) ->
       case deserialiseWithOrFail (decode api ty) (serialiseEncoding (encode v)) of
         Right v' | v /= v'   -> QCP.failed { QCP.reason = "Expected " ++ show v
                                                             ++ " but got " ++ show v' }
                  | otherwise -> QCP.succeeded
         Left err             -> QCP.failed { QCP.reason = "Parse error: " ++ err }


-- | QuickCheck property that the type-specific CBOR serialisation
-- agrees with deserialising as generic CBOR and then serialising again
prop_cborGeneric :: CBOR.Serialise a => API -> TypeName -> a -> QCP.Result
prop_cborGeneric api tn x = case deserialiseWithOrFail (decode napi (TyName tn)) bs of
    Right v | bs' <- serialiseEncoding (encode v)
            , bs' /= bs -> QCP.failed { QCP.reason = "Expected " ++ show bs ++ " but got " ++ show bs' }
            | otherwise      -> QCP.succeeded
    Left err                 -> QCP.failed { QCP.reason = "Decode error: " ++ err }
  where
    napi = apiNormalForm api
    bs = serialiseEncoding (CBOR.encode x)


lookupSet :: Ord a => a -> Set.Set a -> Maybe a
lookupSet k s = flip Set.elemAt s <$> Set.lookupIndex k s

lookupMap :: Ord k => k -> Map.Map k a -> Maybe (k, a)
lookupMap k m = flip Map.elemAt m <$> Map.lookupIndex k m
