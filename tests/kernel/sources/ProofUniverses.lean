universe u

namespace ProofUniverses

axiom Wrapped (α : Sort u) : Sort u
axiom left (α : Sort u) : Wrapped α
axiom right (α : Sort u) : Wrapped α

-- The result universe can become zero. These distinct opaque values are then
-- proofs, so conversion must use proof irrelevance without unfolding them.
theorem collapsed (P : Prop) : left P = right P := rfl

end ProofUniverses
