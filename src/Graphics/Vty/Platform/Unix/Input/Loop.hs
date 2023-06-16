{-# LANGUAGE CPP #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_HADDOCK hide #-}
-- | The input layer used to be a single function that correctly
-- accounted for the non-threaded runtime by emulating the terminal
-- VMIN adn VTIME handling. This has been removed and replace with a
-- more straightforward parser. The non-threaded runtime is no longer
-- supported.
--
-- This is an example of an algorithm where code coverage could be high,
-- even 100%, but the behavior is still under tested. I should collect
-- more of these examples...
--
-- reference: http://www.unixwiz.net/techtips/termios-vmin-vtime.html
module Graphics.Vty.Platform.Unix.Input.Loop
  ( initInput
  )
where

import Graphics.Vty.Config
import Graphics.Vty.Input
import Graphics.Vty.Input.Classify.Types
import Graphics.Vty.Input.Events

import Graphics.Vty.Platform.Unix.Input.Classify

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception (mask, try, SomeException)
import Lens.Micro hiding ((<>~))
import Lens.Micro.Mtl
import Control.Monad (when, mzero, forM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.State (StateT(..), evalStateT)
import Control.Monad.State.Class (MonadState, modify)
import Control.Monad.Trans.Reader (ReaderT(..))

import Lens.Micro.TH

import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString as BS
import Data.ByteString.Char8 (ByteString)
import Data.IORef
import Data.Word (Word8)

import Foreign (allocaArray)
import Foreign.C.Types (CInt(..))
import Foreign.Ptr (Ptr, castPtr)

import System.Posix.IO (fdReadBuf, setFdOption, FdOption(..))
import System.Posix.Types (Fd(..))

data InputBuffer = InputBuffer
    { _ptr :: Ptr Word8
    , _size :: Int
    }

makeLenses ''InputBuffer

data InputState = InputState
    { _unprocessedBytes :: ByteString
    , _classifierState :: ClassifierState
    , _appliedConfig :: Config
    , _inputBuffer :: InputBuffer
    , _classifier :: ClassifierState -> ByteString -> KClass
    }

makeLenses ''InputState

type InputM a = StateT InputState (ReaderT Input IO) a

logMsg :: String -> InputM ()
logMsg msg =
    error "FIXME: was: d <- view inputDebug; case d of Nothing -> return (); Just h -> liftIO $ hPutStrLn h msg >> hFlush h"

-- this must be run on an OS thread dedicated to this input handling.
-- otherwise the terminal timing read behavior will block the execution
-- of the lightweight threads.
loopInputProcessor :: InputM ()
loopInputProcessor = do
    readFromDevice >>= addBytesToProcess
    validEvents <- many parseEvent
    forM_ validEvents emit
    dropInvalid
    loopInputProcessor

addBytesToProcess :: ByteString -> InputM ()
addBytesToProcess block = unprocessedBytes <>= block

emit :: Event -> InputM ()
emit event = do
    logMsg $ "parsed event: " ++ show event
    view eventChannel >>= liftIO . atomically . flip writeTChan (InputEvent event)

-- The timing requirements are assured by the VMIN and VTIME set for the
-- device.
--
-- Precondition: Under the threaded runtime. Only current use is from a
-- forkOS thread. That case satisfies precondition.
readFromDevice :: InputM ByteString
readFromDevice = do
    newConfig <- view configRef >>= liftIO . readIORef
    oldConfig <- use appliedConfig
    let Just fd = inputFd newConfig
    when (newConfig /= oldConfig) $ do
        logMsg $ "new config: " ++ show newConfig
        liftIO $ applyConfig fd newConfig
        appliedConfig .= newConfig
    bufferPtr <- use $ inputBuffer.ptr
    maxBytes  <- use $ inputBuffer.size
    stringRep <- liftIO $ do
        -- The killThread used in shutdownInput will not interrupt the
        -- foreign call fdReadBuf uses this provides a location to be
        -- interrupted prior to the foreign call. If there is input on
        -- the FD then the fdReadBuf will return in a finite amount of
        -- time due to the vtime terminal setting.
        threadWaitRead fd
        bytesRead <- fdReadBuf fd bufferPtr (fromIntegral maxBytes)
        if bytesRead > 0
        then BS.packCStringLen (castPtr bufferPtr, fromIntegral bytesRead)
        else return BS.empty
    when (not $ BS.null stringRep) $
        logMsg $ "input bytes: " ++ show (BS8.unpack stringRep)
    return stringRep

applyConfig :: Fd -> Config -> IO ()
applyConfig fd (Config{ vmin = Just theVmin, vtime = Just theVtime })
    = setTermTiming fd theVmin (theVtime `div` 100)
applyConfig _ _ = fail "(vty) applyConfig was not provided a complete configuration"

parseEvent :: InputM Event
parseEvent = do
    c <- use classifier
    s <- use classifierState
    b <- use unprocessedBytes
    case c s b of
        Valid e remaining -> do
            logMsg $ "valid parse: " ++ show e
            logMsg $ "remaining: " ++ show remaining
            classifierState .= ClassifierStart
            unprocessedBytes .= remaining
            return e
        _ -> mzero

dropInvalid :: InputM ()
dropInvalid = do
    c <- use classifier
    s <- use classifierState
    b <- use unprocessedBytes
    case c s b of
        Chunk -> do
            classifierState .=
                case s of
                  ClassifierStart -> ClassifierInChunk b []
                  ClassifierInChunk p bs -> ClassifierInChunk p (b:bs)
            unprocessedBytes .= BS8.empty
        Invalid -> do
            logMsg "dropping input bytes"
            classifierState .= ClassifierStart
            unprocessedBytes .= BS8.empty
        _ -> return ()

runInputProcessorLoop :: ClassifyMap -> Input -> IO ()
runInputProcessorLoop classifyTable input = do
    let bufferSize = 1024
    allocaArray bufferSize $ \(bufferPtr :: Ptr Word8) -> do
        s0 <- InputState BS8.empty ClassifierStart
                <$> readIORef (_configRef input)
                <*> pure (InputBuffer bufferPtr bufferSize)
                <*> pure (classify classifyTable)
        runReaderT (evalStateT loopInputProcessor s0) input

initInput :: Config -> ClassifyMap -> IO Input
initInput config classifyTable = do
    let Just fd = inputFd config
    setFdOption fd NonBlockingRead False
    applyConfig fd config
    stopSync <- newEmptyMVar
    input <- Input <$> atomically newTChan
                   <*> pure (return ())
                   <*> pure (return ())
                   <*> newIORef config
    inputThread <- forkOSFinally (runInputProcessorLoop classifyTable input)
                                 (\_ -> putMVar stopSync ())
    let killAndWait = do
          killThread inputThread
          takeMVar stopSync
    return $ input { shutdownInput = killAndWait }

foreign import ccall "vty_set_term_timing" setTermTiming :: Fd -> Int -> Int -> IO ()

forkOSFinally :: IO a -> (Either SomeException a -> IO ()) -> IO ThreadId
forkOSFinally action and_then =
  mask $ \restore -> forkOS $ try (restore action) >>= and_then

(<>=) :: (MonadState s m, Monoid a) => ASetter' s a -> a -> m ()
l <>= a = modify (l <>~ a)

(<>~) :: Monoid a => ASetter s t a a -> a -> s -> t
l <>~ n = over l (`mappend` n)