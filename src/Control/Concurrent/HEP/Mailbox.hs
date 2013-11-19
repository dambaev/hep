{-#LANGUAGE DeriveDataTypeable #-}
{-#LANGUAGE BangPatterns#-}


module Control.Concurrent.HEP.Mailbox 
    ( newMBox
    , sendMBox
    , receiveMBox
    , receiveMBoxAfter
    , receiveMBoxAfterTMVar
    )where
    
import Control.Concurrent.HEP.Types
import Control.Concurrent.STM
import Control.Concurrent
import System.Timeout

newMBox:: IO (MBox a)
newMBox = do
    !a <- atomically $! newTQueue -- newTChan
    return $! LocalMBox a

sendMBox:: MBox m-> m -> IO ()
sendMBox (LocalMBox !mbox) !m = do
    atomically $! writeTQueue mbox m
    --yield

receiveMBoxAfterTMVar:: TMVar (Maybe a) -> TimeoutType-> MBox a-> IO (Maybe a)
receiveMBoxAfterTMVar !tmvar !tm (LocalMBox !mbox) = do -- timeout (tm * 1000) $! receiveMBox mbox
    --yield
    atomically $! readTMVar tmvar `orElse` 
        ( readTQueue mbox >>= (return . Just))

    
receiveMBoxAfter:: TimeoutType-> MBox a-> IO (Maybe a)
receiveMBoxAfter !tm !mbox = timeout (tm * 1000) $! receiveMBox mbox


receiveMBox:: MBox a-> IO a
receiveMBox (LocalMBox !mbox) = do  
    --yield
    atomically $! readTQueue mbox
