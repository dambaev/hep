{-#LANGUAGE DeriveDataTypeable #-}
{-#LANGUAGE BangPatterns#-}

module Control.Concurrent.HEP.Supervisor 
    ( SupervisorMessage(..)
    , SupervisorCommand
--    , spawnSupervisor
    , procContinue
    , procFinish
    , procRestart
    , procReshutdown
    ) where
    
import Control.Concurrent.HEP.Types
import Control.Concurrent.HEP.Mailbox
import Control.Exception
import Data.Typeable
import Control.Concurrent.HEP.Proc
import Control.Monad.Trans


{-spawnSupervisor:: (HEP HEPProcState-> HEP Pid) -> (Pid-> HEP HEPProcState ) -> HEP HEPProcState -> HEP Pid
spawnSupervisor forker sv worker = do
    !pid <- forker worker
    spawn (sv pid)
    return pid
-}

procContinue:: MBox SupervisorCommand-> HEP ()
procContinue mbox = do
    liftIO $! sendMBox mbox $! ProcContinue

procFinish:: MBox SupervisorCommand-> HEP ()
procFinish mbox = do
    liftIO $! sendMBox mbox $! ProcFinish

procRestart:: MBox SupervisorCommand-> Maybe HEPSomeLocalState -> HEP ()
procRestart mbox mstate = do
    liftIO $! sendMBox mbox $! ProcRestart mstate

procReshutdown:: MBox SupervisorCommand-> Maybe HEPSomeLocalState -> HEP ()
procReshutdown mbox mstate = do
    liftIO $! sendMBox mbox $! ProcReshutdown mstate