{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}

-- | SQL Server database API.

module Database.ODBC.SQLServer
  ( -- * Building
    -- $building

    -- * Basic library usage
    -- $usage

    -- * Connect/disconnect
    Internal.connect
  , Internal.close
  , Internal.Connection

    -- * Executing queries
  , exec
  , query
  , Value(..)
  , Query
  , ToSql(..)
  , FromValue(..)
  , FromRow(..)

    -- * Streaming results
    -- $streaming

  , stream
  , Internal.Step(..)

    -- * Exceptions
    -- $exceptions

  , Internal.ODBCException(..)
  , renderQuery
  ) where


import           Control.DeepSeq
import           Control.Exception
import           Control.Monad.IO.Class
import           Control.Monad.IO.Unlift
import           Data.ByteString (ByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import           Data.Char
import           Data.Data
import           Data.Foldable
import           Data.Monoid
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import           Data.String
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import           Data.Word
import           Database.ODBC.Conversion
import           Database.ODBC.Internal (Value(..), Connection)
import qualified Database.ODBC.Internal as Internal
import qualified Formatting
import           GHC.Generics

-- $building
--
-- You have to compile your projects using the @-threaded@ flag to
-- GHC. In your .cabal file, this would look like:
--
-- @
-- ghc-options: -threaded
-- @

-- $usage
--
-- An example program using this library:
--
-- @
-- {-\# LANGUAGE OverloadedStrings \#-}
-- import Database.ODBC
-- main :: IO ()
-- main = do
--   conn <-
--     connect
--       "DRIVER={ODBC Driver 13 for SQL Server};SERVER=192.168.99.100;Uid=SA;Pwd=Passw0rd"
--   exec conn "DROP TABLE IF EXISTS example"
--   exec conn "CREATE TABLE example (id int, name ntext, likes_tacos bit)"
--   exec conn "INSERT INTO example VALUES (1, \'Chris\', 0), (2, \'Mary\', 1)"
--   rows <- query conn "SELECT * FROM example" :: IO [[Maybe Value]]
--   print rows
--   rows2 <- query conn "SELECT * FROM example" :: IO [(Int,Text,Bool)]
--   print rows2
--   close conn
-- @
--
-- The @rows@ list contains rows of some value that could be
-- anything. The @rows2@ list contains tuples of exactly @Int@,
-- @Text@ and @Bool@. This is achieved via the 'FromRow' class.
--
-- You need the @OverloadedStrings@ extension so that you can write
-- 'Text' values for the queries and executions.
--
-- The output of this program for @rows@:
--
-- @
-- [[Just (IntValue 1),Just (TextValue \"Chris\"),Just (BoolValue False)],[Just (IntValue 2),Just (TextValue \"Mary\"),Just (BoolValue True)]]
-- @
--
-- The output for @rows2@:
--
-- @
-- [(1,\"Chris\",False),(2,\"Mary\",True)]
-- @

-- $exceptions
--
-- Proper connection handling should guarantee that a close happens at
-- the right time. Here is a better way to write it:
--
-- @
-- {-\# LANGUAGE OverloadedStrings \#-}
-- import Control.Exception
-- import Database.ODBC.SQLServer
-- main :: IO ()
-- main =
--   bracket
--     (connect
--        "DRIVER={ODBC Driver 13 for SQL Server};SERVER=192.168.99.100;Uid=SA;Pwd=Passw0rd")
--     close
--     (\\conn -> do
--        rows <- query conn "SELECT N'Hello, World!'"
--        print rows)
-- @
--
-- If an exception occurs inside the lambda, 'bracket' ensures that
-- 'close' is called.

-- $streaming
--
-- Loading all rows of a query result can be expensive and use a lot
-- of memory. Another way to load data is by fetching one row at a
-- time, called streaming.
--
-- Here's an example of finding the longest string from a set of
-- rows. It outputs @"Hello!"@. We only work on 'Text', we ignore
-- for example the @NULL@ row.
--
-- @
-- {-\# LANGUAGE OverloadedStrings, LambdaCase \#-}
-- import qualified Data.Text as T
-- import           Control.Exception
-- import           Database.ODBC.SQLServer
-- main :: IO ()
-- main =
--   bracket
--     (connect
--        \"DRIVER={ODBC Driver 13 for SQL Server};SERVER=192.168.99.101;Uid=SA;Pwd=Passw0rd\")
--     close
--     (\\conn -> do
--        exec conn \"DROP TABLE IF EXISTS example\"
--        exec conn \"CREATE TABLE example (name ntext)\"
--        exec
--          conn
--          \"INSERT INTO example VALUES (\'foo\'),(\'bar\'),(NULL),(\'mu\'),(\'Hello!\')\"
--        longest <-
--          stream
--            conn
--            \"SELECT * FROM example\"
--            (\\longest mtext ->
--               pure
--                 (Continue
--                    (maybe
--                       longest
--                       (\\text ->
--                          if T.length text > T.length longest
--                            then text
--                            else longest)
--                       mtext)))
--            \"\"
--        print longest)
-- @

--------------------------------------------------------------------------------
-- Types

-- | A query builder.  Use 'toSql' to convert Haskell values to this
-- type safely.
--
-- It's an instance of 'IsString', so you can use @OverloadedStrings@
-- to produce plain text values e.g. @"SELECT 123"@.
--
-- It's an instance of 'Monoid', so you can append fragments together
-- with '<>' e.g. @"SELECT * FROM x WHERE id = " <> toSql 123@.
--
-- This is meant as a bare-minimum of safety and convenience.
newtype Query =
  Query (Seq Part)
  deriving (Monoid, Eq, Show, Typeable, Ord, Generic, Data)

instance NFData Query

instance IsString Query where
  fromString = Query . Seq.fromList . pure . fromString

-- | A part of a query.
data Part
  = TextPart !Text
  | ValuePart !Value
  deriving (Eq, Show, Typeable, Ord, Generic, Data)

instance NFData Part

instance IsString Part where
  fromString = TextPart . T.pack

--------------------------------------------------------------------------------
-- Conversion to SQL

-- | Handy class for converting values to a query safely.
--
-- For example: @query c (\"SELECT * FROM demo WHERE id > \" <> toSql 123)@
class ToSql a where
  toSql :: a -> Query

-- | Converts whatever the 'Value' is to SQL.
instance ToSql Value where
  toSql = Query . Seq.fromList . pure . ValuePart

-- | Corresponds to NTEXT of SQL Server.
instance ToSql Text where
  toSql = toSql . TextValue

-- | Corresponds to NTEXT of SQL Server.
instance ToSql LT.Text where
  toSql = toSql . TextValue . LT.toStrict

-- | Corresponds to BINARY or TEXT of SQL Server.
instance ToSql ByteString where
  toSql = toSql . ByteStringValue

-- | Corresponds to BINARY or TEXT of SQL Server.
instance ToSql L.ByteString where
  toSql = toSql . ByteStringValue . L.toStrict

-- | Corresponds to BIT type of SQL Server.
instance ToSql Bool where
  toSql = toSql . BoolValue

-- | Corresponds to FLOAT type of SQL Server.
instance ToSql Double where
  toSql = toSql . DoubleValue

-- | Corresponds to FLOAT type of SQL Server.
instance ToSql Float where
  toSql = toSql . FloatValue

-- | Corresponds to BIGINT type of SQL Server.
instance ToSql Int where
  toSql = toSql . IntValue

-- | Corresponds to TINYINT type of SQL Server.
instance ToSql Word8 where
  toSql = toSql . ByteValue

--------------------------------------------------------------------------------
-- Top-level functions

-- | Query and return a list of rows.
--
-- The @row@ type is inferred based on use or type-signature. Examples
-- might be @(Int, Text, Bool)@ for concrete types, or @[Maybe Value]@
-- if you don't know ahead of time how many columns you have and their
-- type. See the top section for example use.
query ::
     (MonadIO m, FromRow row)
  => Connection -- ^ A connection to the database.
  -> Query -- ^ SQL query.
  -> m [row]
query c (Query ps) = do
  rows <- Internal.query c (renderParts (toList ps))
  case mapM fromRow rows of
    Right rows' -> pure rows'
    Left e -> liftIO (throwIO (Internal.DataRetrievalError e))

renderQuery :: Query -> Text
renderQuery (Query ps) = (renderParts (toList ps))

-- | Stream results like a fold with the option to stop at any time.
stream ::
     (MonadIO m, MonadUnliftIO m, FromRow row)
  => Connection -- ^ A connection to the database.
  -> Query -- ^ SQL query.
  -> (state -> row -> m (Internal.Step state))
  -- ^ A stepping function that gets as input the current @state@ and
  -- a row, returning either a new @state@ or a final @result@.
  -> state
  -- ^ A state that you can use for the computation. Strictly
  -- evaluated each iteration.
  -> m state
  -- ^ Final result, produced by the stepper function.
stream c (Query ps) cont nil =
  Internal.stream
    c
    (renderParts (toList ps))
    (\state row ->
       case fromRow row of
         Left e -> liftIO (throwIO (Internal.DataRetrievalError e))
         Right row' -> cont state row')
    nil

-- | Execute a statement on the database.
exec ::
     MonadIO m
  => Connection -- ^ A connection to the database.
  -> Query -- ^ SQL statement.
  -> m ()
exec c (Query ps) = Internal.exec c (renderParts (toList ps))

--------------------------------------------------------------------------------
-- Query building

-- | Convert a list of parts into a query.
renderParts :: [Part] -> Text
renderParts = T.concat . map renderPart

-- | Render a query part to a query.
renderPart :: Part -> Text
renderPart =
  \case
    TextPart t -> t
    ValuePart v -> renderValue v

-- | Render a value to a query.
renderValue :: Value -> Text
renderValue =
  \case
    TextValue t -> "(N'" <> T.concatMap escapeChar t <> "')"
    ByteStringValue xs -> "('" <> T.concat (map escapeChar8 (S.unpack xs)) <> "')"
    BoolValue True -> "1"
    BoolValue False -> "0"
    ByteValue n -> Formatting.sformat Formatting.int n
    DoubleValue d -> Formatting.sformat Formatting.float d
    FloatValue d -> Formatting.sformat Formatting.float (realToFrac d :: Double)
    IntValue d -> Formatting.sformat Formatting.int d

-- | A very conservative character escape.
escapeChar8 :: Word8 -> Text
escapeChar8 ch =
  if allowedChar (toEnum (fromIntegral ch))
     then T.singleton (toEnum (fromIntegral ch))
     else "'+CHAR(" <> Formatting.sformat Formatting.int ch <> ")+'"

-- | A very conservative character escape.
escapeChar :: Char -> Text
escapeChar ch =
  if allowedChar ch
     then T.singleton ch
     else "'+NCHAR(" <> Formatting.sformat Formatting.int (fromEnum ch) <> ")+'"

-- | Is the character allowed to be printed unescaped? We only print a
-- small subset of ASCII just for visually debugging later
-- on. Everything else is escaped.
allowedChar :: Char -> Bool
allowedChar c = (isAlphaNum c && isAscii c) || elem c (" ,.-_" :: [Char])