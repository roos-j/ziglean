inductive NestedTree where
  | node : List (List NestedTree) → NestedTree
  | branch : List (List NestedTree) → List NestedTree → NestedTree
