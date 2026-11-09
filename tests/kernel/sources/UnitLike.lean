import Init

namespace ZigleanRegression

structure ProofBox : Prop where
  proof : True

structure EmptyBox : Type where

structure NestedUnit : Type where
  box : ProofBox
  unit : Unit

theorem proofBoxEta (a b : ProofBox) : a = b := rfl
theorem emptyBoxEta (a b : EmptyBox) : a = b := rfl
theorem nestedUnitExt (a b : NestedUnit) : a = b := by
  cases a
  cases b
  rfl
theorem functionUnitExt (f g : Nat -> NestedUnit) : f = g :=
  funext (fun n => nestedUnitExt (f n) (g n))

end ZigleanRegression
