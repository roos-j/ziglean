import Lean

set_option maxRecDepth 100000
set_option maxHeartbeats 0

-- Closed computations exercise the data path, including Bool.false and Nat.
def nbeDataSum (n : Nat) : Nat := (List.range n).foldl (fun a b => a + b) 0

theorem nbeDataSumCorrect : nbeDataSum 128 = 8128 := by decide
theorem nbeDataNat : nbeDataSum 128 = 8128 := rfl
theorem nbeDataFalse : decide (nbeDataSum 128 = 0) = false := rfl

-- Repeated calls become hot. Simplifying their open bodies must preserve
-- native arithmetic; expanding comparison into recursion on this bound is huge.
def nbeLargeComparisons : Bool :=
  (List.range 64).all (fun n => Nat.blt (n + 1000000000000000000) 2000000000000000000)

theorem nbeLargeComparisonsCorrect : nbeLargeComparisons = true := by decide
