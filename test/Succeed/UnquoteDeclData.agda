{-# OPTIONS --erasure #-}
module UnquoteDeclData where

open import Agda.Builtin.Nat
open import Agda.Builtin.Unit
open import Agda.Builtin.Sigma
open import Agda.Builtin.Reflection
open import Common.Reflection
open import Common.List


defineD : Name → Name → Quantity → TC _
defineD n c q =
  declareData n 1 (pi (vArg (quoteTerm Set))
                      (abs "" (pi (vArg (quoteTerm Nat))
                                  (abs "" (quoteTerm Set))))) >>= λ _ →
  defineData n ((c , q
                   , pi (vArg (def (quote List) (vArg (var 0 []) ∷ [])))
                       (abs "" (def n (vArg (var 1 [])
                                      ∷ vArg (def (quote length)
                                                  (vArg (var 0 []) ∷ []))
                                        ∷ [])))) ∷ [])

unquoteDecl data newD  constructor newC  = defineD newD  newC  quantity-ω
unquoteDecl data newD0 constructor newC0 = defineD newD0 newC0 quantity-0

j : newD Nat 0
j = newC []

k : newD Nat 2
k = newC (10 ∷ 20 ∷ [])

@0 j0 : newD0 Nat 0
j0 = newC0 []
