import Init

namespace ZigleanRegression

theorem bigProduct : (18446744073709551619 : Nat) * 18446744073709551621 = 340282366920938463610948560021444624399 := rfl
theorem gcdZero : Nat.gcd 0 0 = 0 := rfl
theorem bigShift : (1 : Nat) <<< 130 = 1361129467683753853853498429727072845824 := rfl
theorem unicodeList : "α😀".toList = ['α', '😀'] := rfl

def stringLength : Nat := "α😀".length
theorem stringLength_eq : stringLength = 2 := rfl

end ZigleanRegression
