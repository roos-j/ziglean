import Init

namespace ZigleanRegression

structure FunctionBox where
  function : Nat -> Nat -> Nat

def subtractionBox : FunctionBox := ⟨Nat.sub⟩

-- Forcing the projection must preserve the primitive's argument spine.
theorem projectedPrimitive : subtractionBox.function 1000000 999999 = 1 := rfl

def symbolicBox (n : Nat) : FunctionBox := ⟨fun x y => x - (n + y)⟩

-- Expose the projected function without evaluating an open addition whose
-- recursive argument is enormous. Congruence can compare it symbolically.
theorem symbolicProjection (n : Nat) :
    (symbolicBox n).function (2 ^ 32) (2 ^ 31) = (2 ^ 32) - (n + 2 ^ 31) := rfl

def eraseInput (_ : Nat) : Nat := 1114111

theorem eagerComparison (n : Nat) : (1114111 == eraseInput n) = true := by
  exact id (α := (1114111 == eraseInput n) = true) (eagerReduce (Eq.refl true))

def longProof (n : Nat) : True :=
  Nat.rec True.intro (fun _ previous => previous) n

-- Conversion must use proof irrelevance before evaluating this recursion.
theorem irrelevantComputation : HEq (longProof 1000000000) True.intro := HEq.rfl

end ZigleanRegression
