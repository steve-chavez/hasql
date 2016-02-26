module Hasql.Private.PreparedStatementRegistry
(
  PreparedStatementRegistry,
  new,
  update,
  LocalKey(..),
)
where

import Hasql.Prelude hiding (lookup)
import qualified Data.HashTable.IO as A
import qualified ByteString.TreeBuilder as B


data PreparedStatementRegistry =
  PreparedStatementRegistry !(A.BasicHashTable LocalKey ByteString) !(IORef Word)

{-# INLINABLE new #-}
new :: IO PreparedStatementRegistry
new =
  PreparedStatementRegistry <$> A.new <*> newIORef 0

{-# INLINABLE update #-}
update :: LocalKey -> (ByteString -> IO (Bool, a)) -> (ByteString -> IO a) -> PreparedStatementRegistry -> IO a
update localKey onNewRemoteKey onOldRemoteKey (PreparedStatementRegistry table counter) =
  lookup >>= maybe new old
  where
    lookup =
      A.lookup table localKey
    new =
      readIORef counter >>= onN
      where
        onN n =
          do
            (save, result) <- onNewRemoteKey remoteKey
            when save $ do
              A.insert table localKey remoteKey
              writeIORef counter (succ n)
            return result
          where
            remoteKey =
              B.toByteString . B.asciiIntegral $ n
    old =
      onOldRemoteKey


-- |
-- Local statement key.
data LocalKey =
  LocalKey !ByteString ![Word32]
  deriving (Show, Eq)

instance Hashable LocalKey where
  {-# INLINE hashWithSalt #-}
  hashWithSalt salt (LocalKey template types) =
    hashWithSalt salt template
