module Control.Concurrent.TaskWorker

import Data.List
import Data.Bits
import Data.Maybe
import Data.IORef
import Data.Queue
import System.Concurrency
import System.Concurrency.RC2

%default total

-------------------------------------------------------------------------------
-- Types

record ThreadPool where
  constructor MkThreadPool
  mutex : Mutex
  --
  notEmpty : Condition
  runQueue : IORef (Queue (IO ()))
  --
  tokenPool : IORef Bits64
  doneTasks : IORef Bits64
  taskDone : Condition

record Promise (a : Type) where
  constructor MkPromise
  token : Int
  result : IORef (Maybe a)


-- global thread pool (RC2 backend always memoize CAFs, so this is safe)
globalThreadPool : ThreadPool
globalThreadPool = unsafePerformIO $ do
  pure $ MkThreadPool {
    mutex = !(makeMutex),
    notEmpty = !(makeCondition),
    runQueue = !(newIORef empty),
    tokenPool = !(newIORef 0xffffffffffffffff), -- 64-bit token pool, all bits set to 1 (free)
    doneTasks = !(newIORef 0),
    taskDone = !(makeCondition)
  }


-------------------------------------------------------------------------------
-- Function / Operation

%inline %foreign "RC2:__builtin_ctzll"
prim__ctzll : Bits64 -> Int


-------------------------------------------------------------------------------
-- Function / Operation

export
submitTask : IO a -> IO (Maybe (Promise a))
submitTask task = do
  let pool = globalThreadPool
  mutexAcquire pool.mutex
  -- allocate new token
  tokens <- readIORef pool.tokenPool
  if tokens == 0
    then mutexRelease pool.mutex >> pure Nothing
    else do
      let newtoken = prim__ctzll tokens
      case (natToFin (cast $ newtoken) 64) of
        Nothing => mutexRelease pool.mutex >> pure Nothing
        Just b => do
          writeIORef pool.tokenPool $ setBit tokens b
          --
          result <- newIORef Nothing
          let f = do
            r <- task
            writeIORef result $ Just r
            modifyIORef pool.doneTasks (\x => setBit x b)
            conditionSignal pool.taskDone
          modifyIORef pool.runQueue (\q => enqueue f q)
          conditionSignal pool.notEmpty
          --
          mutexRelease pool.mutex
          pure $ Just $ MkPromise newtoken result


covering export
runWorker : (stop : IO Bool) -> IO ()
runWorker stop = go where 
  go = do
    let pool = globalThreadPool
    mutexAcquire pool.mutex
    case dequeue !(readIORef pool.runQueue) of
      Nothing => do
        if !(stop)
          then mutexRelease pool.mutex -- exit loop
          else do
            conditionWait pool.notEmpty pool.mutex
            go
      Just (tsk, q') => do
        writeIORef pool.runQueue q'
        mutexRelease pool.mutex
        tsk
        go


export
waitPromise : Promise a -> IO a

