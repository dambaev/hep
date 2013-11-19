{-#LANGUAGE DeriveDataTypeable #-}
{-#LANGUAGE BangPatterns#-}

module Control.Concurrent.HEP.Proc 
    ( parentMBox
    , self
    , selfMBox
    , send
    , setMBox
    , spawn
    , proc
    , procWithBracket
    , procWithSupervisor
    , procForker
    , procRegister
--    , spawnBracket
--    , spawnBracketOS
--    , spawnLink
--    , spawnOS
    , runHEPGlobal
    , localState
    , setLocalState
    , killChilds
    , receive
    , register
    , receiveMaybe
    , receiveAfter
    , linkProc
    , unlinkProc
    , getSubscribed
    , procRunning
    , procFinished
    , toPid
    ) where

import Control.Concurrent.HEP.Types
import Control.Concurrent.HEP.Mailbox
import Control.Monad.State.Strict
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM.TMVar
import Control.Concurrent.STM
import Control.Concurrent
import Control.Exception as E
import Data.Maybe
import Data.UUID
import Data.UUID.V1
import Data.Typeable
import Data.Map.Strict as M

data ParentAnswer = ParentProcMBox (MBox SomeMessage)
                  | ParentNotAProc
                  | ParentError String
                  | ParentSpawnedProc Pid
                  | ParentProcRegistered
                  | ParentProcAlreadyRegistered


data ParentMessage = ParentGetMBox Pid (MBox ParentAnswer)
                   | ParentSpawnProc HEPProcOptions (MBox ParentAnswer)
                   | ParentRegisterProc Pid Pid (MBox SomeMessage) (MBox ParentAnswer)
                   | ParentKillChilds Pid
    deriving Typeable

instance Message ParentMessage

parentMBox:: HEP (MBox SomeMessage)
parentMBox = do
    !s <- get
    return $! fromJust $! hepParentMBox s

self:: HEP Pid
self = do
    !s <- get
    return $! hepSelf s

selfRaw:: HEP Pid
selfRaw = do
    !s <- get
    return $! hepRawPid s

selfMBox:: HEP (MBox SomeMessage)
selfMBox = do
    !s <- get 
    return $! fromJust $! hepSelfMBox s

toPid = ProcName


storeInPidCache:: Pid-> (MBox SomeMessage) -> HEP ()
storeInPidCache !pid !mbox = do
    !s <- get
    let !cache = hepPidCache s
    case M.size cache >= hepCacheSize s of
        False-> put $! s { hepPidCache = M.insert pid mbox cache}
        True -> do
            let !first = head $! M.keys cache
            put $! s { hepPidCache = M.insert pid mbox $! 
                M.delete first cache}

send:: (Message m) => Pid -> m -> HEP ()
send !pid !msg = do
    !mprocmbox <- getProcMBox pid
    case mprocmbox of
        Just !procmbox -> do
            liftIO $! sendMBox procmbox $ toMessage msg
            return ()
        _ -> do
            liftIO $! ioError $! userError $! "proc " ++  
                ": " ++ show pid ++ " does not exists"
            return ()



receiveAfter:: TimeoutType -> HEP (Maybe SomeMessage)
receiveAfter 0 = receive >>= (return . Just)
receiveAfter tm = do
    !mbox <- selfMBox
    let reader = do
            !ret <- liftIO $! receiveMBoxAfter tm mbox
            case ret of
                Nothing-> return Nothing
                Just some -> do
                    !svc <- handleServiceMessage $! fromMessage some
                    handleChildLinkMessage $! fromMessage some
                    case svc of
                        True -> reader
                        _ -> return ret
    reader

receiveMaybe:: HEP (Maybe SomeMessage)
receiveMaybe = do
    LocalMBox !mbox <- selfMBox
    isempty <- liftIO $! atomically $! isEmptyTQueue mbox
    case isempty of
        True -> return Nothing
        _ -> receiveAfter 0


receive:: HEP SomeMessage
receive = do
    !mbox <- selfMBox
    !ret <- liftIO $! receiveMBox mbox
    !svc <- handleServiceMessage $! fromMessage ret
    handleChildLinkMessage $! fromMessage ret
    case svc of
        True -> receive
        _ -> return ret

handleChildLinkMessage:: Maybe LinkedMessage-> HEP Bool
handleChildLinkMessage Nothing = return False
handleChildLinkMessage (Just (ProcessFinished !pid)) = do
    delSubscribe pid
    return False

handleServiceMessage:: Maybe ServiceMessage-> HEP Bool
handleServiceMessage Nothing = return False
handleServiceMessage (Just (SubscribeRequest !pid)) = do
    addLinkedProc pid
    return True
handleServiceMessage (Just (UnsubscribeRequest !pid)) = do
    delLinkedProc pid
    return True
handleServiceMessage (Just (SubscriberFinished !pid)) = do
    delLinkedProc pid
    return True

spawn:: HEPProcOptions -> HEP Pid
spawn opts = do
    !pmbox <- parentMBox
    !answ <- liftIO $! do
        !inbox <- liftIO $! newMBox
        sendMBox pmbox $! toMessage $! ParentSpawnProc opts
            inbox
        !_<-yield
        receiveMBox inbox
    case answ of
        ParentSpawnedProc !pid -> return pid
        _ -> liftIO $! throwIO $! userError $! 
            "spawn: parent returned error on spawn"


register:: String -> HEP Bool
register name = do
    let pid = toPid name
    !mmbox <- getProcMBox pid
    case mmbox of
        Just _ -> return False
        Nothing -> do
            !mybox <- selfMBox
            !curpid <- self
            !pmbox <- parentMBox
            !inbox <- liftIO $ newMBox
            liftIO $! sendMBox pmbox $! toMessage $! ParentRegisterProc curpid pid mybox inbox
            !ret <- liftIO $! receiveMBox inbox
            case ret of
                ParentProcRegistered -> do
                    setCurrentPid pid
                    return True
                _ -> return False
    
setCurrentPid:: Pid-> HEP ()
setCurrentPid !newpid = do
    !s <- get
    put $! s { hepSelf = newpid}

    
    
notifyLinkedProcShutdown:: HEP ()
notifyLinkedProcShutdown = do
    !mypid <- self
    !myrawpid <- selfRaw
    !pmbox <- parentMBox
    !linkedPids <- getLinkedPids
    liftIO $! sendMBox pmbox $! toMessage $! ProcessFinished mypid
    forM_ linkedPids $! \pid -> do
        send pid $! ProcessFinished mypid
        send pid $! ProcessFinished myrawpid
    !subscribers <- getSubscribed
    forM_ subscribers $! \subscriber -> do
        send subscriber $! SubscriberFinished mypid
        send subscriber $! SubscriberFinished myrawpid
        delSubscribe subscriber
    
    
getLinkedPids:: HEP [Pid]
getLinkedPids = do
    !s <- get
    return $! hepLinkedWithProcs s

localState:: (HEPLocalState a) => HEP (Maybe  a)
localState = do
    !s <- get
    let !ls = hepLocalState s
    case ls of
        Nothing -> return Nothing
        Just some -> return $! fromLocalState some
        
setLocalState:: (HEPLocalState a) => Maybe a-> HEP ()
setLocalState Nothing = do
    !s <- get
    put $! s { hepLocalState = Nothing}
setLocalState (Just some) = do
    !s<- get
    put $! s {hepLocalState = Just $! toLocalState some}

killChilds:: HEP ()
killChilds = do
    !pid <- self
    !pmbox <- parentMBox
    liftIO $! sendMBox pmbox $! toMessage $! ParentKillChilds pid

 
{-spawnLink:: HEP HEPProcState-> HEP Pid
spawnLink proc = do
    !pid <- spawn proc
    linkProc pid
    return pid
-}

linkProc:: Pid-> HEP ()
linkProc !pid = do
    !mypid <- self
    send pid $! SubscribeRequest mypid
    addSubscribe pid

unlinkProc:: Pid-> HEP ()
unlinkProc !pid = do
    !mypid <- self
    send pid $! UnsubscribeRequest mypid
    delSubscribe pid
            


parentPid = ProcName "0"

{-
-- TODO: rewrite
newPid:: HEPGlobal Pid
newPid = do
    s <- get
    let !newpid = case M.keys (hepgProcList s) of
            [] -> 1
            list -> let Pid some = last list
                in some + 1
    return $! Pid newpid
-}

newPid:: HEPGlobal Pid
newPid = do
    muuid <- liftIO $! nextUUID
    case muuid of
        Nothing -> liftIO $! ioError $! userError "nextUUID failed!"
        Just uuid -> return $! Pid uuid

runHEPGlobal:: HEPProcOptions->  IO ()
runHEPGlobal main = do
    !mbox <- newMBox
    let !state = HEPGlobalState
            { hepgSelfMBox = mbox
            , hepgRegProcList = M.empty
            , hepgProcList = M.empty
            , hepgRunningProcs = M.empty
            , hepgSelf = ProcName "0"
            }
    runStateT (runStateT ( realSpawn main >> parentMain) state) defaultHEPState
    return ()

runHEP':: Pid
      -> (IO () -> IO ThreadId) -- forker
      -> Maybe Pid -- supervisor
      -> Maybe Pid -- subscribeTo
      -> Maybe String -- register
      -> HEPState -- state
      -> HEP () --proc
      -> HEPGlobal Pid
runHEP' !newpid !fork sv@(Just !svpid)  !subscribeTo !mname !state !proc 
    | svpid `notElem` hepLinkedWithProcs state = 
        runHEP' newpid fork sv subscribeTo mname state 
            { hepLinkedWithProcs = svpid:(hepLinkedWithProcs state)
            }
            proc
runHEP' !newpid !fork !sv  subscribeTo@(Just !subscriberpid) !mname !state !proc
    | subscriberpid `notElem` hepSubscribedToProcs state = 
        runHEP' newpid fork sv subscribeTo mname state 
            { hepSubscribedToProcs = subscriberpid:(hepSubscribedToProcs state)
            }
            proc
runHEP' !newpid !fork !sv  !subscribeTo mname@(Just !name) !state !proc
    | hepSelf state /= toPid name  = do
        storeNewRegisteredProc newpid $! toPid name
        runHEP' newpid fork sv subscribeTo mname state 
            { hepSelf = toPid name
            }
            proc
runHEP' !newpid !fork !sv  !subscribeTo !mname !state !proc = do
    !tid <- liftIO $! fork $! runStateT proc state >> return ()
    storeNewThread newpid tid
    return newpid



runHEP:: Pid
      -> (IO () -> IO ThreadId) -- forker
      -> Maybe Pid -- supervisor
      -> Maybe Pid -- subscribeTo
      -> Maybe String -- register
      -> HEP () --proc
      -> HEPGlobal Pid
runHEP !newpid fork !sv !subscribeTo !mname !proc = do
    !mbox <- liftIO $! (newMBox:: IO (MBox SomeMessage))
    storeNewProc newpid mbox
    s <- get
    let !pmbox = hepgSelfMBox s
        !state = setMBox mbox $! setParentMBox pmbox $! setPid newpid $! 
            setRawPid newpid $! defaultHEPState
    runHEP' newpid fork sv subscribeTo mname state proc

    
storeNewProc:: Pid-> MBox SomeMessage-> HEPGlobal ()
storeNewProc !pid !mbox = do
    s <- get
    let !prev = hepgProcList s
        !new = insert pid mbox prev
    case ( M.lookup pid prev ) of
        Nothing -> put $! s { hepgProcList = new }
        Just _ -> liftIO $! ioError $! userError $! show pid ++ "is already stored!"

storeNewThread:: Pid-> ThreadId -> HEPGlobal ()
storeNewThread !pid !tid = do
    s <- get
    let !prev = hepgRunningProcs s
        !new = insert pid tid prev
    put $! s { hepgRunningProcs = new }

storeNewRegisteredProc:: Pid-> Pid -> HEPGlobal ()
storeNewRegisteredProc !rawpid !namepid = do
    s <- get
    let !prev = hepgRegProcList s
        !new = insert namepid rawpid prev
    put $! s { hepgRegProcList = new }

childsRunning:: HEPGlobal Bool
childsRunning = do
    !s <- get 
    return $! M.size (hepgProcList s) > 0

parentMain:: HEPGlobal ()
parentMain = do
    !s <- get
    let !inbox = hepgSelfMBox s
    !mreq  <- liftIO $! receiveMBoxAfter 1000 inbox
    case mreq of
        Nothing -> do
            !isrunning <- childsRunning
            if isrunning then parentMain
                else return ()
        Just !req -> do
            handleLinkedMessage $! fromMessage req
            handleParentMessage $! fromMessage req
            parentMain

realSpawn::HEPProcOptions-> HEPGlobal Pid
realSpawn opts = do
    !newpid <- newPid
    !maybesv <- case heppSupervisor opts of
        Nothing -> return Nothing
        Just sv -> realSpawn (procSubscribeTo newpid sv) >>= (return . Just)
    runHEP newpid (heppSpawner opts) maybesv (heppSubscribeTo opts) 
        (heppRegisterProc opts) $! procWrapperBracket 
            (heppInit opts) (heppWorker opts) (heppShutdown opts)

handleParentMessage::Maybe ParentMessage-> HEPGlobal ()
handleParentMessage Nothing = return ()
handleParentMessage (Just (ParentSpawnProc !opts !mbox))= do
    !pid <- realSpawn opts -- forkIO $! procWrapperBracket procRunning proc procFinished
    liftIO $! sendMBox mbox (ParentSpawnedProc pid)

handleParentMessage (Just (ParentGetMBox !pid@(Pid _) !mbox)) = do
    !s <- get
    let !map = hepgProcList s
        !ret = case M.lookup pid map of
                Just !mb-> ParentProcMBox mb
                _ -> case M.lookup pid (hepgRegProcList s) of 
                    Just rawpid -> case M.lookup pid map of
                        Just !mb -> ParentProcMBox mb
                        _ -> ParentNotAProc
                    _ -> ParentNotAProc
    liftIO $! sendMBox mbox $! ret
handleParentMessage (Just (ParentGetMBox !pid@(ProcName _) !mbox)) = do
    !s <- get
    let !map = hepgRegProcList s
        !ret = case pid == parentPid of
            True -> ParentProcMBox $! hepgSelfMBox s
            _ -> case M.lookup pid map of
                Just !intpid -> case M.lookup intpid (hepgProcList s) of
                    Just !mb -> ParentProcMBox mb
                    _ -> ParentNotAProc
                _ -> ParentNotAProc
    liftIO $! sendMBox mbox $! ret
handleParentMessage (Just (ParentRegisterProc !intpid@(Pid _) 
                    !namepid@(ProcName _) !mbox !outbox)) = do
    !s <- get
    let !map = hepgRegProcList s
    case M.member namepid map of
        True -> do
            liftIO $! sendMBox outbox ParentProcAlreadyRegistered
        _ -> do
            put $! s { hepgRegProcList = M.insert namepid intpid map}
            liftIO $! sendMBox outbox ParentProcRegistered
handleParentMessage (Just (ParentRegisterProc !intpid
                    !namepid !mbox !outbox)) = do
    liftIO $! sendMBox outbox $! ParentError "args must be (Pid ProcName ...)"
handleParentMessage (Just (ParentKillChilds !sender)) = do
    !s <- get
    let !map = hepgRunningProcs s
    forM_ (M.elems map) $! \tid ->
        liftIO $! do
            killThread tid
    put $! s { hepgProcList = M.empty, hepgRegProcList = M.empty}

handleLinkedMessage:: Maybe LinkedMessage -> HEPGlobal ()
handleLinkedMessage Nothing = return ()
handleLinkedMessage (Just (ProcessFinished !pid@(Pid _))) = do
    !s <- get
    let !procs = hepgProcList s
    put $! s { hepgProcList = M.delete pid procs}
    let !regprocs = hepgRegProcList s
    case M.filter (==pid) regprocs of
        some | some == M.empty -> return ()
        filteredMap -> do   
            let !(intpid, _) = head $! toList filteredMap
            put $! s { hepgRegProcList = M.delete intpid regprocs}
handleLinkedMessage (Just (ProcessFinished !pid)) = do
    !s <- get
    let !procs = hepgRegProcList s
    case M.lookup pid procs of
        Nothing -> return ()
        Just rawpid -> do
            put $! s { hepgProcList = M.delete rawpid (hepgProcList s)}

getProcMBox:: Pid -> HEP (Maybe (MBox SomeMessage))
getProcMBox pid = do
    !s <- get 
    !pmbox <- parentMBox
    let !cache = hepPidCache s
    case M.lookup pid cache of
        Just mbox-> return $! Just mbox
        _ -> do
            !inbox <- liftIO $! newMBox
            liftIO $! sendMBox pmbox $! toMessage $! ParentGetMBox pid inbox
            !ret <- liftIO $! receiveMBox inbox
            case ret of
                    ParentProcMBox !procmbox -> do
                        storeInPidCache pid procmbox
                        return $! Just procmbox
                    _ -> return Nothing


procWrapperBracket:: HEPProc -> HEPProc -> HEPProc -> HEP ()
procWrapperBracket init proc shutdown = do
    !s <- get
    !tmstate <- liftIO $! newTVarIO s
    let runOnce:: HEPProc -> IO HEPProcState
        runOnce _proc = do
            --yield
            !_state <- readTVarIO tmstate
            (!val, !newstate) <- runStateT _proc _state
            atomically $! writeTVar tmstate newstate
            return val
        initHandler:: SomeException -> IO HEPProcState
        initHandler e = do
            case fromException e of
                Just ThreadKilled ->do
                    return HEPFinished
                _ -> do
                    !inbox <- newMBox
                    !state <- readTVarIO tmstate
                    let !pids = hepLinkedWithProcs state
                        !mypid = hepSelf state
                    case length pids of
                        0 -> do
                            throw e
                            return HEPFinished
                        _ -> do
                            forM pids $! \pid -> do
                                runStateT (send pid $! ProcInitFailure mypid e state inbox) state
                            !ret <- receiveMBox inbox
                            case ret of
                                (ProcRestart newstate) -> do
                                    atomically $! writeTVar tmstate $! state {hepLocalState = newstate}
                                    return HEPRestart
                                _ -> return HEPFinished
        shutdownHandler:: SomeException -> IO HEPProcState
        shutdownHandler e = do
            case fromException e of
                Just ThreadKilled ->do
                    !state <- readTVarIO tmstate
                    runStateT notifyLinkedProcShutdown state
                    return HEPFinished
                _ -> do
                    !inbox <- newMBox
                    !state <- readTVarIO tmstate
                    let !pids = hepLinkedWithProcs state
                        !mypid = hepSelf state
                    case length pids of
                        0 -> do
                            throw e
                            return HEPFinished
                        _ -> do
                            forM pids $! \pid -> do
                                runStateT (send pid $! ProcShutdownFailure mypid e state inbox) state
                            !ret <- receiveMBox inbox
                            case ret of
                                (ProcReshutdown newstate) -> do
                                    atomically $! writeTVar tmstate $! state {hepLocalState = newstate}
                                    return HEPRestart
                                ProcFinish -> return HEPFinished
        handler:: SomeException -> IO HEPProcState
        handler e = do
            case fromException e of
                Just ThreadKilled -> return HEPFinished
                _ -> do
                    !inbox <- newMBox
                    !state <- readTVarIO tmstate
                    let !pids = hepLinkedWithProcs state
                        !mypid = hepSelf state
                    case length pids of
                        0 -> do
                            throw e
                            return HEPFinished
                        _ -> do
                            forM pids $! \pid -> do
                                runStateT (send pid $! ProcWorkerFailure mypid e state inbox) state
                            !ret <- receiveMBox inbox
                            case ret of
                                ProcContinue -> return HEPRunning
                                (ProcRestart newstate) -> do
                                    atomically $! writeTVar tmstate $! state {hepLocalState = newstate}
                                    return HEPRestart
                                ProcFinish -> return HEPFinished
        worker = do
            let stepWorker :: IO HEPProcState
                stepWorker = do
                    yield 
                    !_state <- readTVarIO tmstate
                    (!val, !newstate) <- runStateT proc _state
                    atomically $! writeTVar tmstate newstate
                    case val of
                        HEPRunning -> stepWorker
                        _ -> return val

                
            !ret <- E.catch stepWorker handler
            case ret of
                HEPRunning -> worker
                _ -> return ret
        runInit = do
            !ret <- E.catch ( runOnce init) initHandler
            case ret of
                HEPRestart -> runInit
                _ -> return ret
        runShutdown = do
            !ret <- E.catch ( runOnce (do
                shutdown 
                notifyLinkedProcShutdown
                return HEPFinished
                )) 
                shutdownHandler
            case ret of
                HEPRestart -> runShutdown
                _ -> return ()
        runProc = do
            !initret  <- runInit
            !workerret <- if initret /= HEPRunning then return initret
                        else worker
            if workerret == HEPRestart then runProc
                        else do
                            runShutdown
                            return ()
    liftIO $! runProc
        


setPid:: Pid-> HEPState -> HEPState
setPid pid s = s{ hepSelf = pid}

setRawPid:: Pid-> HEPState -> HEPState
setRawPid pid s = s{ hepRawPid = pid}

setLinkPid:: Pid-> HEPState -> HEPState
setLinkPid pid s = s{ hepLinkedWithProcs = [pid]}

_setLocalState:: Maybe HEPSomeLocalState-> HEPState -> HEPState
_setLocalState !lstate !s = s{ hepLocalState = lstate}

setParentMBox:: MBox SomeMessage-> HEPState -> HEPState
setParentMBox mbox s = s{ hepParentMBox = Just mbox}

setMBox:: MBox SomeMessage-> HEPState -> HEPState
setMBox mbox s = s{ hepSelfMBox = Just mbox}

procRunning:: HEP HEPProcState
procRunning = return HEPRunning

procFinished:: HEP HEPProcState
procFinished = return HEPFinished

procRestart:: HEP HEPProcState
procRestart = return HEPRestart

procReshutdown = procRestart


addSubscribe:: Pid -> HEP ()
addSubscribe pid = do
    mypid <- self
    when ( pid /= mypid) $! do
        !s <- get
        let list = hepSubscribedToProcs s
        when ( pid `notElem` list) $! put $! 
            s { hepSubscribedToProcs = pid:list}

delSubscribe:: Pid -> HEP ()
delSubscribe pid = do
    mypid <- self
    when (pid /= mypid) $! do
        !s <- get
        let list = hepSubscribedToProcs s
        put $! s { hepSubscribedToProcs = Prelude.filter (/=pid) list}

getSubscribed:: HEP [Pid]
getSubscribed = do
    !s <- get
    return $! hepSubscribedToProcs s
        
addLinkedProc:: Pid -> HEP ()
addLinkedProc pid = do
    mypid <- self
    when ( pid /= mypid) $! do
        !s <- get
        let list = hepLinkedWithProcs s
        when (pid `notElem` list) $! put $! 
            s { hepLinkedWithProcs = pid:list}
    
delLinkedProc:: Pid -> HEP ()
delLinkedProc pid = do
    mypid <- self
    when ( pid /= mypid) $! do
        !s <- get
        let list = hepLinkedWithProcs s
        put $! s { hepLinkedWithProcs = Prelude.filter (/=pid) list}
        
defaultProcOptions = HEPProcOptions
    { heppInit = procRunning
    , heppShutdown = procFinished
    , heppWorker = procFinished
    , heppSupervisor = Nothing
    , heppSpawner = forkIO
    , heppRegisterProc = Nothing
    , heppSubscribeTo = Nothing
    }

procWithBracket:: HEPProc-> HEPProc-> HEPProcOptions -> HEPProcOptions
procWithBracket init shut opts = opts
    { heppInit = init
    , heppShutdown = shut
    }

procWithSupervisor:: HEPProcOptions-> HEPProcOptions-> HEPProcOptions
procWithSupervisor sv opts = opts 
    { heppSupervisor = Just sv
    }

proc:: HEPProc -> HEPProcOptions
proc proc = defaultProcOptions
    { heppWorker = proc
    }

procForker:: (IO () -> IO ThreadId)-> HEPProcOptions -> HEPProcOptions
procForker foo opts = opts 
    { heppSpawner = foo
    }

procRegister:: String-> HEPProcOptions -> HEPProcOptions
procRegister name opts = opts 
    { heppRegisterProc = Just name
    }

procSubscribeTo:: Pid -> HEPProcOptions-> HEPProcOptions
procSubscribeTo pid opts = opts 
    { heppSubscribeTo = Just pid
    }
