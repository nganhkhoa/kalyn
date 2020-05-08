module RegisterAllocator
  ( allocateProgramRegs
  )
where

import           Data.List
import qualified Data.Map                      as Map
import qualified Data.Set                      as Set

import           Assembly
import           Liveness

-- http://web.cs.ucla.edu/~palsberg/course/cs132/linearscan.pdf

computeLivenessInterval
  :: Ord reg => Map.Map Int (Set.Set reg, Set.Set reg) -> reg -> (Int, Int)
computeLivenessInterval intervalMap reg =
  let indices = filter (\idx -> reg `Set.member` fst (intervalMap Map.! idx))
                       (Map.keys intervalMap)
  in  (head indices, last indices + 1)

intervalsIntersect :: (Int, Int) -> (Int, Int) -> Bool
intervalsIntersect (a, b) (c, d) = not (b <= c || d <= a)

tryAllocateFunctionRegs
  :: VirtualFunction -> Either [Temporary] PhysicalFunction
tryAllocateFunctionRegs fn@(Function _ _ instrs) =
  let liveness = assertNoFreeVariables . computeLiveness $ instrs
      allRegs =
          ( nub
          $ concatMap
              (\(liveIn, liveOut) -> Set.toList liveIn ++ Set.toList liveOut)
          $ Map.elems liveness
          )
      intervalMap = Map.fromList
        $ map (\reg -> (reg, computeLivenessInterval liveness reg)) allRegs
      disallowed = Map.mapWithKey
        (\reg _ -> Set.fromList $ filter
          (\dataReg ->
            Physical dataReg `Map.member` intervalMap && intervalsIntersect
              (intervalMap Map.! reg)
              (intervalMap Map.! Physical dataReg)
          )
          dataRegisters
        )
        intervalMap
      (spilled, allocation) = allocate
        []
        (Map.fromList (map (\reg -> (fromRegister reg, reg)) specialRegisters))
        -- allocate to smaller live intervals first, hopefully meaning
        -- we spill less
        (sortOn
          (\reg -> let (start, end) = intervalMap Map.! reg in end - start)
          allRegs
        )
         where
          allocate spills allocs [] = (spills, allocs)
          allocate spills allocs (cur@(Physical phys) : rst) =
            allocate spills (Map.insert cur phys allocs) rst
          allocate spills allocs (cur@(Virtual temp) : rst) =
            case
                filter
                  (\dataReg ->
                    not (dataReg `Set.member` (disallowed Map.! cur)) && not
                      (any
                        (\other ->
                          Map.lookup other allocs
                            == Just dataReg
                            && intervalsIntersect (intervalMap Map.! cur)
                                                  (intervalMap Map.! other)
                        )
                        allRegs
                      )
                  )
                  dataRegisters
              of
                []       -> allocate (temp : spills) allocs rst
                free : _ -> allocate spills (Map.insert cur free allocs) rst
  in  case spilled of
        [] -> Right $ mapFunction
          (\reg -> case reg `Map.lookup` allocation of
            Nothing   -> error $ "register " ++ show reg ++ " was never live"
            Just reg' -> reg'
          )
          fn
        _ -> Left spilled

spillMem :: Eq reg => reg -> Mem reg -> Bool
spillMem reg (Mem _ base msi) =
  base
    == reg
    || (case msi of
         Nothing       -> False
         Just (_, idx) -> idx == reg
       )

spillInstr :: Eq reg => reg -> Mem reg -> Instruction reg -> [Instruction reg]
spillInstr dir ind (OP op (IR imm reg)) | reg == dir = [OP op (IM imm ind)]
spillInstr dir ind (OP op (IM imm mem)) | spillMem dir mem =
  [OP MOV $ MR ind dir, OP op (IM imm mem)]
spillInstr dir ind (OP op (RR src dst))
  | src == dir && dst == dir = [OP MOV $ MR ind dir, OP op $ RM dir ind]
  | src == dir               = [OP MOV $ MR ind dst]
  | dst == dir               = [OP MOV $ RM src ind]
spillInstr dir ind (OP op (MR mem dst))
  | spillMem dir mem && dst == dir
  = [OP MOV $ MR ind dir, OP op $ MR mem dir, OP MOV $ RM dir ind]
  | spillMem dir mem
  = [OP MOV $ MR ind dir, OP op $ MR mem dst]
  | dst == dir
  = [OP MOV $ MR mem dir, OP op $ RM dir ind]
spillInstr dir ind (OP op (RM src mem))
  | spillMem dir mem = [OP MOV $ MR ind dir, OP op $ RM src mem]
  | src == dir       = [OP MOV $ MR ind dir, OP op $ RM dir mem]
spillInstr dir ind (UN op (R dst)) | dst == dir = [UN op (M ind)]
spillInstr dir ind (UN op (M mem)) | spillMem dir mem =
  [OP MOV $ MR ind dir, UN op (M mem)]
spillInstr dir ind (MOV64 imm dst) | dst == dir =
  [MOV64 imm dir, OP MOV $ RM dir ind]
spillInstr dir ind (SHIFT amt op dst) | dst == dir =
  [OP MOV $ MR ind dir, SHIFT amt op dir, OP MOV $ RM dir ind]
spillInstr dir ind (LEA mem dst) | spillMem dir mem && dst == dir =
  [OP MOV $ MR ind dir, LEA mem dst, OP MOV $ RM dir ind]
spillInstr dir ind (LEA mem dst) | spillMem dir mem =
  [OP MOV $ MR ind dir, LEA mem dst]
spillInstr dir ind (LEA mem dst) | dst == dir =
  [LEA mem dir, OP MOV $ RM dir ind]
spillInstr dir ind (IDIV src) | src == dir = [OP MOV $ MR ind dir, IDIV dir]
spillInstr _ _ instr                       = [instr]

spillFunction :: Eq reg => reg -> Mem reg -> Function reg -> Function reg
spillFunction dir ind (Function name stackSpace instrs) =
  Function name stackSpace . concatMap (spillInstr dir ind) $ instrs

spillTemporary :: Int -> Temporary -> VirtualFunction -> VirtualFunction
spillTemporary spillIdx temp = spillFunction
  (Virtual temp)
  (Mem (Right . fromIntegral $ -(spillIdx + 1) * 8) rbp Nothing)

allocateFunctionRegs :: Int -> VirtualFunction -> PhysicalFunction
allocateFunctionRegs numSpilled fn = case tryAllocateFunctionRegs fn of
  Right (Function stackSpace name instrs) ->
    Function (stackSpace + numSpilled * 8) name instrs
  Left spilled -> allocateFunctionRegs (numSpilled + length spilled) $ foldr
    (uncurry spillTemporary)
    fn
    (zip (iterate (+ 1) numSpilled) spilled)

allocateProgramRegs :: Program VirtualRegister -> Program Register
allocateProgramRegs (Program main fns datums) = Program
  (allocateFunctionRegs 0 main)
  (map (allocateFunctionRegs 0) fns)
  datums
