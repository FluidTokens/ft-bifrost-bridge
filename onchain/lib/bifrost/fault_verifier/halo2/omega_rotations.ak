use aiken/collection/list.{map, range}
use aiken/crypto/bitwise.{State}
use aiken/crypto/bls12_381/scalar.{Scalar, from_int, mul, scale}
use aiken/math.{abs}

pub fn rotate_omegas(
  omega: State<Scalar>,
  omega_inv: State<Scalar>,
  from: Int,
  to: Int,
) -> List<State<Scalar>> {
  map(
    range(from, to),
    fn(value) { rotate_omega(omega, omega_inv, from_int(1), value) },
  )
}

pub fn rotate_omega(
  omega: State<Scalar>,
  omega_inv: State<Scalar>,
  value: State<Scalar>,
  rotation: Int,
) -> State<Scalar> {
  if rotation < 0 {
    mul(scale(omega_inv, abs(rotation)), value)
  } else {
    mul(scale(omega, rotation), value)
  }
}

fn go(
  first: State<Scalar>,
  num: Int,
  base: State<Scalar>,
) -> List<State<Scalar>> {
  if num == 0 {
    []
  } else {
    [first, ..go(mul(base, first), num - 1, base)]
  }
}

pub fn powers(num: Int, base: State<Scalar>) -> List<State<Scalar>> {
  go(from_int(1), num, base)
}
