{-#LANGUAGE DeriveDataTypeable #-}
{-#LANGUAGE BangPatterns#-}
{-#LANGUAGE ExistentialQuantification #-}
module Control.Concurrent.HEP.Types where

--import Control.Concurrent.STM.TQueue
import Control.Concurrent
import Control.Exception
import Data.UUID
import Control.Concurrent.STM.TQueue
import Control.Monad.State.Strict
import Data.Typeable
import Data.Map.Strict as M

type PidT = UUID
type ProcNameT = String
type TimeoutType = Int

data Pid = Pid PidT
         | ProcName ProcNameT
    deriving (Eq, Show)
instance Ord Pid where
    (Pid a) `compare` (Pid b) = a `compare` b
    (Pid a) `compare` (ProcName b) = LT
    (ProcName a) `compare` (Pid b) = GT
    (ProcName a) `compare` (ProcName b) = a `compare` b


class (Typeable a) => Message a where
    toMessage:: a -> SomeMessage
    toMessage = SomeMessage
    
    fromMessage:: SomeMessage -> Maybe a
    fromMessage (SomeMessage !a) = cast a

data SomeMessage = forall a . Message a => SomeMessage a
    deriving Typeable

class (Typeable a) => HEPLocalState a where
    toLocalState:: a -> HEPSomeLocalState
    toLocalState = HEPSomeLocalState
    
    fromLocalState:: HEPSomeLocalState -> Maybe a
    fromLocalState (HEPSomeLocalState !a) = cast a

data HEPSomeLocalState = forall a. HEPLocalState a => HEPSomeLocalState  a
    deriving Typeable

data MBox a = LocalMBox !(TQueue a) 

type CacheSizeT = Int

data HEPState = HEPState
    { hepSelf:: Pid
    , hepRawPid:: Pid
    , hepSelfMBox:: Maybe (MBox SomeMessage)
    , hepParentMBox:: Maybe (MBox SomeMessage)
    , hepCacheSize:: CacheSizeT
    , hepPidCache:: !(Map Pid (MBox SomeMessage))
    , hepLinkedWithProcs:: [Pid]
    , hepSubscribedToProcs:: [Pid]
    , hepLocalState:: Maybe HEPSomeLocalState
    }

defaultHEPCacheSize = 100

defaultHEPState = HEPState
    { hepPidCache = M.empty
    , hepCacheSize = defaultHEPCacheSize
    , hepLinkedWithProcs = []
    , hepSubscribedToProcs = []
    , hepSelf = ProcName "self"
    , hepRawPid = ProcName "dummy"
    , hepLocalState = Nothing
    , hepSelfMBox = Nothing
    , hepParentMBox = Nothing
    }

data HEPGlobalState = HEPGlobalState
    { hepgProcList:: !(Map Pid (MBox SomeMessage))
    , hepgRegProcList:: !(Map Pid Pid)
    , hepgRunningProcs:: !(Map Pid ThreadId)
    , hepgSelfMBox:: !(MBox SomeMessage)
    , hepgSelf:: !Pid
    }

type HEPGlobal = StateT HEPGlobalState HEP

type HEP = StateT HEPState IO

data HEPProcState = HEPRunning 
                  | HEPFinished
                  | HEPRestart
      deriving Eq

data LinkedMessage = ProcessFinished Pid 
    deriving Typeable
instance Message LinkedMessage

data ServiceMessage = SubscribeRequest Pid
                    | UnsubscribeRequest Pid
                    | SubscriberFinished Pid
    deriving Typeable
instance Message ServiceMessage

data SupervisorMessage 
    = ProcInitFailure Pid SomeException HEPState (MBox SupervisorCommand)
    | ProcWorkerFailure Pid SomeException HEPState (MBox SupervisorCommand)                
    | ProcShutdownFailure Pid SomeException HEPState (MBox SupervisorCommand)
    deriving Typeable
instance Message SupervisorMessage

data SupervisorCommand = ProcContinue
                       | ProcRestart (Maybe HEPSomeLocalState)
                       | ProcFinish
                       | ProcReshutdown (Maybe HEPSomeLocalState)

type HEPProc = HEP HEPProcState

data HEPProcOptions = HEPProcOptions
    { heppInit:: HEPProc
    , heppShutdown :: HEPProc
    , heppWorker :: HEPProc
    , heppSupervisor:: Maybe HEPProcOptions
    , heppSpawner :: (IO () -> IO ThreadId)
    , heppRegisterProc:: Maybe String
    , heppSubscribeTo:: Maybe Pid
    }
