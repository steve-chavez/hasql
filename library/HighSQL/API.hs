module HighSQL.API where

import HighSQL.Prelude hiding (read, Read, write, Write, Error)
import qualified Data.Pool as Pool
import qualified HighSQL.CompositionT as CompositionT
import qualified HighSQL.Backend as Backend
import qualified HighSQL.Conversion as Conversion
import qualified ListT


-- * Pool
-------------------------

-- |
-- A pool of connections to the database.
newtype Pool = 
  Pool (Pool.Pool Backend.Connection)

-- |
-- Pool initization settings.
data Settings =
  Settings {
    -- | 
    -- The number of stripes (distinct sub-pools) to maintain. 
    -- The smallest acceptable value is 1.
    striping1 :: Word32,
    -- |
    -- The maximum number of connections to keep open per a pool stripe. 
    -- The smallest acceptable value is 1.
    -- Requests for connections will block if this limit is reached 
    -- on a single stripe, 
    -- even if other stripes have idle connections available.
    striping2 :: Word32,
    -- |
    -- The amount of time for which an unused connection is kept open. 
    -- The smallest acceptable value is 0.5 seconds.
    connectionTimeout :: NominalDiffTime
  }

-- |
-- Initialize a pool given a backend and settings 
-- and run an IO computation with it, 
-- while automating the resource management.
withPool :: Backend.Backend -> Settings -> (Pool -> IO a) -> IO a
withPool b s =
  bracket acquire release
  where
    acquire = 
      do
        pool <-
          Pool.createPool 
            (Backend.connect b) (Backend.disconnect) (striping1 s)
            (connectionTimeout s) (striping2 s)
        return (Pool pool)
    release (Pool pool) =
      Pool.purgePool pool


-- * Error
-------------------------

-- |
-- The only exception type that this API can raise.
data Error =
  -- |
  -- Cannot connect to a server 
  -- or the connection got interrupted.
  ConnectionError Text |
  -- |
  -- Attempt to parse a statement execution result into an incompatible type.
  -- Indicates either a mismatching schema or an incorrect query.
  ResultParsingError [Backend.Value] TypeRep |
  -- |
  -- A free-form backend-specific exception.
  BackendError SomeException
  deriving (Show, Typeable)

instance Exception Error


-- * Transaction
-------------------------

-- |
-- A transaction with a level @l@,
-- running on an anonymous state-thread @s@ 
-- and gaining a result @r@.
newtype T l s r =
  T (CompositionT.T (ReaderT Backend.Connection IO) r)
  deriving (Functor, Applicative, Monad)

-- |
-- Execute a transaction in a write mode (if 'True') using a connections pool.
-- 
-- * Automatically determines, 
-- whether it's actually a transaction or just a single action
-- and executes accordingly.
-- 
-- * Automatically retries the transaction in case of a
-- 'Backend.TransactionError' exception.
-- 
-- * Rethrows all the other exceptions after wrapping them in 'Error'.
transaction :: Bool -> Pool -> (forall s. T l s r) -> IO r
transaction w (Pool p) (T t) = 
  do 
    e <-
      try $ Pool.withResource p $ 
        \c -> 
          case CompositionT.run t of
            (False, r) -> 
              runReaderT r c
            (True, r) ->
              retry
              where
                retry = 
                  do
                    Backend.beginTransaction c w
                    e <- try $ runReaderT r c
                    case e of
                      Left (Backend.TransactionError) ->
                        do
                          Backend.finishTransaction c False
                          retry
                      Left e ->
                        do
                          Backend.finishTransaction c False
                          throwIO e
                      Right r -> 
                        do
                          Backend.finishTransaction c True
                          return r
    case e of
      Left (Backend.ConnectionError t) ->
        throwIO (ConnectionError t)
      Left (Backend.BackendError e) ->
        throwIO (BackendError e)
      Left (Backend.TransactionError) ->
        $bug "Unexpected TransactionError"
      Right r ->
        return r


-- ** Levels
-------------------------

data Read

-- |
-- Execute a transaction on a connections pool.
-- 
-- Requires minimal locking from the database,
-- however you can only execute the \"SELECT\" statements in it. 
-- The API ensures of that on the type-level.
read :: Pool -> (forall s. T Read s r) -> IO r
read = transaction False


data Write

-- |
-- Execute a transaction on a connections pool.
-- 
-- Allows to execute the \"SELECT\", \"UPDATE\", \"INSERT\" 
-- and \"DELETE\" statements.
-- However, compared to 'read', this transaction requires the database to choose 
-- a more resource-demanding locking strategy.
write :: Pool -> (forall s. T Write s r) -> IO r
write = transaction True


data Admin

-- |
-- Execute a transaction on a connections pool.
-- 
-- Same as 'write', but allows you to perform any kind of statements,
-- including \"CREATE\", \"DROP\" and \"ALTER\".
admin :: Pool -> (forall s. T Admin s r) -> IO r
admin = transaction True


-- ** Privileges
-------------------------

-- |
-- \"SELECT\"
class SelectPrivilege l where
  -- | 
  -- Produce a results stream from a statement.
  select :: 
    forall s r. 
    (Conversion.Row r, Typeable r) => Statement -> ResultsStream s (T l s) r
  select (Statement bs vl) = 
    do
      (w, s) <- 
        lift $ T $ lift $ do
          Backend.Connection {..} <- ask
          liftIO $ do
            ps <- prepare bs
            executeStreaming ps vl Nothing
      l <- ResultsStream $ hoist (T . liftIO) $ replicateM w s
      maybe (throwParsingError l (typeOf (undefined :: r))) return $ Conversion.fromRow l
    where
      throwParsingError vl t =
        ResultsStream $ lift $ T $ liftIO $ throwIO $ ResultParsingError vl t

instance SelectPrivilege Read
instance SelectPrivilege Write
instance SelectPrivilege Admin


-- |
-- \"UPDATE\", \"INSERT\", \"DELETE\"
class UpdatePrivilege l where
  -- |
  -- Execute and count the amount of affected rows.
  update :: Statement -> T l s Integer
  update (Statement bs vl) =
    T $ do
      Backend.Connection {..} <- lift $ ask
      liftIO $ do
        ps <- prepare bs
        executeCountingEffects ps vl
  -- |
  -- Execute and return the possibly auto-incremented number.
  insert :: Statement -> T l s (Maybe Integer)
  insert (Statement bs vl) =
    T $ do
      Backend.Connection {..} <- lift $ ask
      liftIO $ do
        ps <- prepare bs
        executeIncrementing ps vl

instance UpdatePrivilege Write
instance UpdatePrivilege Admin


-- |
-- \"CREATE\", \"ALTER\", \"DROP\", \"TRUNCATE\"
class CreatePrivilege l where
  create :: Statement -> T l s ()
  create (Statement bs vl) =
    T $ do
      Backend.Connection {..} <- lift $ ask
      liftIO $ do
        ps <- prepare bs
        execute ps vl

instance CreatePrivilege Admin


-- * Statement
-------------------------

data Statement =
  Statement !ByteString ![Backend.Value]
  deriving (Show)


-- * Results Stream
-------------------------

-- |
-- A stream of results, 
-- which fetches only those that you reach.
-- 
-- It is implemented as a wrapper around 'ListT.ListT',
-- hence all the utility functions of the list transformer API 
-- are applicable to this type.
-- 
-- It uses the same trick as 'ST' to become impossible to be run outside of
-- its transaction.
-- Hence you can only access it while remaining in a transaction,
-- and when the transaction finishes it safely gets automatically released.
newtype ResultsStream s m r =
  ResultsStream (ListT.ListT m r)
  deriving (Functor, Applicative, Alternative, Monad, MonadTrans, MonadPlus, 
            Monoid, ListT.ListMonad, ListT.ListTrans)
