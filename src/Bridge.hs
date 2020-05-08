module Bridge where

import qualified Data.Map                      as Map
import qualified Data.Set                      as Set

import           Assembly
import           MemoryManager
import           Primitives
import           Subroutines

{-# ANN module "HLint: ignore Use lambda-case" #-}

handleUnary
  :: String -> Stateful VirtualFunction -> (String, Stateful [VirtualFunction])
handleUnary name fn = (name, (: []) <$> fn)

handleCurried
  :: Int
  -> String
  -> Stateful VirtualFunction
  -> (String, Stateful [VirtualFunction])
handleCurried n name fn = (name, (:) <$> fn <*> curryify n name)

handleUnaryM
  :: String -> Stateful VirtualFunction -> (String, Stateful [VirtualFunction])
handleUnaryM name fn =
  ( name
  , do
    core       <- fn
    monadified <- monadify 1 name
    return [core, monadified]
  )

handleCurriedM
  :: Int
  -> String
  -> Stateful VirtualFunction
  -> (String, Stateful [VirtualFunction])
handleCurriedM n name fn =
  ( name
  , do
    core       <- fn
    curried    <- curryify n (name ++ "__unmonadified")
    monadified <- monadify n name
    return ([core, monadified] ++ curried)
  )

stdlibPublic :: Map.Map String (String, Stateful [VirtualFunction])
stdlibPublic = Map.fromList
  [ ("+"          , handleCurried 2 "plus" plus)
  , ("-"          , handleCurried 2 "minus" minus)
  , ("*"          , handleCurried 2 "times" times)
  , ("/"          , handleCurried 2 "divide" divide)
  , ("%"          , handleCurried 2 "modulo" modulo)
  , ("&"          , handleCurried 2 "and" bitAnd)
  , ("|"          , handleCurried 2 "or" bitOr)
  , ("^"          , handleCurried 2 "xor" xor)
  , ("~"          , handleUnary "not" bitNot)
  , ("shl"        , handleCurried 2 "shl" shl)
  , ("shr"        , handleCurried 2 "shr" shr)
  , ("sal"        , handleCurried 2 "sal" sal)
  , ("sar"        , handleCurried 2 "sar" sar)
  , ("print"      , handleUnaryM "print" monadPrint)
  , ("writeFile"  , handleCurriedM 2 "writeFile" monadWriteFile)
  , ("setFileMode", handleCurriedM 2 "setFileMode" setFileMode)
  , ("error"      , handleUnary "error" primitiveError)
  , ("=="         , handleCurried 2 "equals" equals)
  , ("<"          , handleCurried 2 "lessThan" lessThan)
  , ("pure"       , handleUnaryM "pure" monadPure)
  , (">>="        , handleCurriedM 2 "bind" monadBind)
  ]

stdlibPrivate :: [Stateful VirtualFunction]
stdlibPrivate = [memoryInit, memoryAlloc, memoryPackString, primitiveCrash]

getCalls :: VirtualFunction -> Set.Set String
getCalls (Function _ instrs) = Set.fromList $ concatMap
  (\instr -> case instr of
    JUMP CALL label -> [label]
    _               -> []
  )
  instrs

stdlibFns :: [VirtualFunction] -> Stateful [VirtualFunction]
stdlibFns fns = do
  let calls = Set.unions . map getCalls $ fns
  public <-
    concat
      <$> ( mapM snd
          . filter (\(name, _) -> name `Set.member` calls)
          . Map.elems
          $ stdlibPublic
          )
  private <- sequence stdlibPrivate
  return $ public ++ private

stdlibData :: [Datum]
stdlibData = [memoryFirstFree, memoryProgramBreak, heap]
