{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ViewPatterns #-}

module Query
  ( parseQuery
  , catalog
  , catalogBulk
  , BulkFormat(..)
  ) where

import           Control.Applicative (empty, (<|>))
import           Control.Monad (guard, unless)
import           Control.Monad.IO.Class (liftIO)
import qualified Data.Aeson as J
import           Data.Bits (xor)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BSC
import           Data.Function (on)
import qualified Data.HashMap.Strict as HM
import           Data.List (foldl', unionBy)
import           Data.Maybe (listToMaybe, maybeToList, fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import           Network.HTTP.Types.Header (hContentType, hContentDisposition, hContentLength)
import           Network.HTTP.Types.Status (ok200, badRequest400)
import qualified Network.Wai as Wai
import           Text.Read (readMaybe)
import           Waimwork.HTTP (quoteHTTP)
import           Waimwork.Response (response, okResponse)
import           Waimwork.Result (result)
import           System.FilePath ((<.>))
import qualified Web.Route.Invertible as R

import Type
import Field
import Catalog
import Global
import Output.CSV
import Output.ECSV
import qualified ES
import Compression
import Output.Numpy

parseQuery :: Catalog -> Wai.Request -> Query
parseQuery cat req = fill $ foldl' parseQueryItem mempty $ Wai.queryString req where
  parseQueryItem q ("offset", Just (rmbs -> Just n)) =
    q{ queryOffset = queryOffset q + n }
  parseQueryItem q ("limit",  Just (rmbs -> Just n)) =
    q{ queryLimit  = queryLimit q `max` n }
  parseQueryItem q ("sort",   Just (mapM parseSort . spld -> Just s)) =
    q{ querySort = querySort q <> s }
  parseQueryItem q ("fields", Just (mapM lookf . spld -> Just l)) =
    q{ queryFields = unionBy ((==) `on` fieldName) (queryFields q) l }
  parseQueryItem q ("sample", Just (rmbs -> Just p)) =
    q{ querySample = querySample q * p }
  parseQueryItem q ("sample", Just (spl ('@' ==) -> Just (rmbs -> Just p, rmbs -> Just s))) =
    q{ querySample = querySample q * p, querySeed = Just $ maybe id xor (querySeed q) s }
  parseQueryItem q ("aggs",   Just (mapM lookf . spld -> Just a)) =
    q{ queryAggs = unionBy eqAgg (queryAggs q) $ map QueryStats a }
  parseQueryItem q ("hist",   Just (parseHist . spld -> Just h)) =
    q{ queryAggs = queryAggs q <> h }
  parseQueryItem q (lookf -> Just f, Just (parseFilt f -> Just v)) =
    q{ queryFilter = queryFilter q <> [liftFilterValue f v] }
  parseQueryItem q _ = q -- just ignore anything we can't parse
  parseSort (BSC.uncons -> Just ('+', lookf -> Just f)) = return (f, True)
  parseSort (BSC.uncons -> Just ('-', lookf -> Just f)) = return (f, False)
  parseSort (lookf -> Just f) = return (f, True)
  parseSort _ = fail "invalid sort"
  parseHist [] = return []
  parseHist ((spl (':' ==) -> Just (lookf -> Just f, histn -> Just n)) : l) = mkHist f n =<< parseHist l
  parseHist ((                      lookf -> Just f                  ) :[]) = return [QueryPercentiles f [0,25,50,75,100]]
  parseHist ((                      lookf -> Just f                  ) : l) = mkHist f (False, 16) =<< parseHist l
  parseHist _ = fail "invalid hist"
  histn s = (t, ) <$> rmbs r where
    (t, r) = maybe (False, s) (True ,) $ BS.stripPrefix "log" s
  parseFilt f (spl delim -> Just (a, b))
    | not (typeIsString (fieldType f)) = FilterRange <$> parseVal f a <*> parseVal f b
  parseFilt f a = FilterEQ <$> parseVal' f a
  parseVal _ "" = return Nothing
  parseVal f v = Just <$> parseVal' f v
  parseVal' f = fmap fieldType . parseFieldValue f . TE.decodeUtf8
  eqAgg (QueryStats f) (QueryStats g) = fieldName f == fieldName g
  eqAgg _ _ = False
  mkHist f (t, n) l
    | typeIsNumeric (fieldType f) = return $ [QueryHist f n t l]
    | otherwise = fail "non-numeric hist"
  fill q@Query{ queryFields = [] } | all (("fields" /=) . fst) (Wai.queryString req) =
    q{ queryFields = filter fieldDisp $ catalogFields cat }
  fill q = q
  spld = BSC.splitWith delim
  delim ',' = True
  delim ' ' = True
  delim _ = False
  rmbs :: Read a => BSC.ByteString -> Maybe a
  rmbs = readMaybe . BSC.unpack
  spl c s = (,) p . snd <$> BSC.uncons r
    where (p, r) = BSC.break c s
  lookf n = HM.lookup (TE.decodeUtf8 n) $ catalogFieldMap cat

catalog :: Route Simulation
catalog = getPath (R.parameter R.>* "catalog") $ \sim req -> do
  cat <- askCatalog sim
  let query = parseQuery cat req
      hsize = histsSize $ queryAggs query
  unless (queryLimit query <= 5000) $
    result $ response badRequest400 [] ("limit too large" :: String)
  unless (hsize > 0 && hsize <= 1024) $
    result $ response badRequest400 [] ("hist too large" :: String)
  case catalogStore cat of
    CatalogES{ catalogStoreField = store } -> do
      res <- ES.queryIndex cat query
      return $ okResponse [] $ clean store res
  where
  histSize (QueryHist _ n _ l) = n * histsSize l
  histSize _ = 1
  histsSize = product . map histSize
  clean store = mapObject $ HM.mapMaybeWithKey (cleanTop store)
  cleanTop _ "aggregations" = Just
  cleanTop _ "histsize" = Just
  cleanTop store "hits" = Just . mapObject (HM.mapMaybeWithKey $ cleanHits store)
  cleanTop _ _ = const Nothing
  cleanHits _ "total" (J.Object o) = HM.lookup "value" o
  cleanHits _ "total" v = Just v
  cleanHits store "hits" a = Just $ mapArray (V.map $ cleanHit store) a
  cleanHits _ _ _ = Nothing
  cleanHit store (J.Object o) = J.Object $ maybe id (HM.insert "_id") (HM.lookup "_id" o) $ fromMaybe HM.empty $ ES.storedFields store o
  cleanHit _ v = v
  mapObject :: (J.Object -> J.Object) -> J.Value -> J.Value
  mapObject f (J.Object o) = J.Object (f o)
  mapObject _ v = v
  mapArray :: (V.Vector J.Value -> V.Vector J.Value) -> J.Value -> J.Value
  mapArray f (J.Array v) = J.Array (f v)
  mapArray _ v = v

data BulkFormat
  = BulkCSV
    { bulkCompression :: Maybe CompressionFormat
    }
  | BulkECSV
    { bulkCompression :: Maybe CompressionFormat
    }
  | BulkNumpy
    { bulkCompression :: Maybe CompressionFormat
    }
  | BulkJSON
    { bulkCompression :: Maybe CompressionFormat
    }
  deriving (Eq)

instance R.Parameter R.PathString BulkFormat where
  parseParameter s = case decompressExtension (T.unpack s) of
    ("csv", z) -> return $ BulkCSV z
    ("ecsv", z) -> return $ BulkECSV z
    ("npy", z) -> return $ BulkNumpy z
    ("numpy", z) -> return $ BulkNumpy z
    ("json", z) -> return $ BulkJSON z
    _ -> empty
  renderParameter = T.pack . formatExtension

formatExtension :: BulkFormat -> String
formatExtension b = bulkExtension $ bulk b undefined undefined 0

data Bulk = Bulk
  { bulkMimeType :: !BS.ByteString
  , bulkExtension :: !String
  , bulkSize :: Maybe Word
  , bulkHeader :: B.Builder
  , bulkRow :: [J.Value] -> B.Builder
  , bulkFooter :: B.Builder
  }

bulkBlock :: Bulk -> [T.Text] -> V.Vector J.Object -> B.Builder
bulkBlock b l = foldMap (\o -> bulkRow b $ map (\f -> HM.lookupDefault J.Null f o) l)

compressBulk :: CompressionFormat -> Bulk -> Bulk
compressBulk z b = b
  { bulkMimeType = compressionMimeType z
  , bulkExtension = bulkExtension b <.> compressionExtension z
  , bulkSize = Nothing
  }

bulk :: BulkFormat -> Catalog -> Query -> Word -> Bulk
bulk (BulkCSV z) _ query _ = maybe id compressBulk z Bulk
  { bulkMimeType = "text/csv"
  , bulkExtension = "csv"
  , bulkSize = Nothing
  , bulkHeader = csvTextRow $ map fieldName $ queryFields query
  , bulkRow = csvJSONRow
  , bulkFooter = mempty
  }
bulk (BulkECSV z) cat query _ = maybe id compressBulk z Bulk
  { bulkMimeType = "text/x-ecsv"
  , bulkExtension = "ecsv"
  , bulkSize = Nothing
  , bulkHeader = ecsvHeader cat query
  , bulkRow = csvJSONRow
  , bulkFooter = mempty
  }
bulk (BulkNumpy z) _ query count = maybe id compressBulk z Bulk
  { bulkMimeType = "application/octet-stream"
  , bulkExtension = "npy"
  , bulkSize = Just size
  , bulkHeader = header
  , bulkRow = numpyRow $ queryFields query
  , bulkFooter = mempty
  } where (header, size) = numpyHeader (queryFields query) count
bulk (BulkJSON z) _ query _ = maybe id compressBulk z Bulk
  { bulkMimeType = "application/json"
  , bulkExtension = "json"
  , bulkSize = Nothing
  , bulkHeader = "[" <> J.fromEncoding (J.toEncoding (map fieldName (queryFields query)))
  , bulkRow = \j -> "," <> J.fromEncoding (J.toEncoding j)
  , bulkFooter = "]"
  }

catalogBulk :: Route (Simulation, BulkFormat)
catalogBulk = getPath (R.parameter R.>*< R.parameter) $ \(sim, fmt) req -> do
  cat <- askCatalog sim
  let query = parseQuery cat req
      enc = bulkCompression fmt <|> listToMaybe (acceptCompressionEncoding req)
      fields = map fieldName $ queryFields query
  nextes <- ES.queryBulk cat query
  (count, block1) <- liftIO nextes
  let b@Bulk{..} = bulk fmt cat query count
  return $ Wai.responseStream ok200 (
    [ (hContentType, bulkMimeType)
    , (hContentDisposition, "attachment; filename=" <> quoteHTTP (TE.encodeUtf8 sim <> BSC.pack ('.' : bulkExtension)))
    ]
    ++ maybeToList ((,) hContentLength . BSC.pack . show <$> bulkSize)
    ++ compressionEncodingHeader (guard (enc /= bulkCompression fmt) >> enc))
    $ compressStream enc $ \chunk _ -> do
    chunk bulkHeader
    case catalogStore cat of
      CatalogES{} -> do
        let loop block = unless (V.null block) $ do
              chunk $ bulkBlock b fields block
              loop . snd =<< nextes
        loop block1
    chunk bulkFooter

