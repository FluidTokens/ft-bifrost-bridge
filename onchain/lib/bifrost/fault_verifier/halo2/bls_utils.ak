use aiken/collection/list.{concat, foldl, map, push, zip}
use aiken/crypto/bitwise.{State}
use aiken/crypto/bls12_381/g1.{add as add_g1, decompress, scale, zero}
use aiken/crypto/bls12_381/scalar.{
  Scalar, add, field_prime, from_int, mul, to_int,
}

pub type MSMElement {
  scalar: State<Scalar>,
  g1: ByteArray,
}

pub type MSM {
  elements: List<MSMElement>,
}

pub fn append_term(msm: MSM, element: MSMElement) -> MSM {
  MSM { elements: push(msm.elements, element) }
}

pub fn add_msm(a: MSM, b: MSM) -> MSM {
  MSM { elements: concat(a.elements, b.elements) }
}

pub fn scale_msm(s: State<Scalar>, msm: MSM) -> MSM {
  MSM {
    elements: map(
      msm.elements,
      fn(e) { MSMElement { g1: e.g1, scalar: mul(s, e.scalar) } },
    ),
  }
}

pub fn eval(msm: MSM) -> G1Element {
  foldl(
    msm.elements,
    zero,
    fn(element, acc) {
      let g1 = decompress(element.g1)
      add_g1(acc, scale(g1, element.scalar))
    },
  )
}

pub fn inner_product(
  a: List<State<Scalar>>,
  b: List<State<Scalar>>,
) -> State<Scalar> {
  foldl(zip(a, b), from_int(0), fn((a, b), acc) { add(mul(a, b), acc) })
}

// TODO: Replace with built-in primitive, once `expModInteger` available in Plutus
/// Fast modular multiplicative inverse using Extended Euclidean Algorithm
/// This is orders of magnitude cheaper than the Fermat-based approach implemented in the Aiken stdlib
pub fn recip_eea(x: State<Scalar>) -> State<Scalar> {
  let a = to_int(x)
  let inv = egcd_go(a, field_prime, 1, 0)
  from_int(inv)
}

/// Extended Euclidean Algorithm for modular inverse
/// Computes x such that (a * x) mod m = 1
/// Invariant: a*x1 + m*x2 = u (mod m)
fn egcd_go(u: Int, v: Int, x1: Int, x2: Int) -> Int {
  if u == 1 {
    // Found inverse, ensure it's positive
    x1 % field_prime
  } else {
    let q = v / u
    let r = v % u
    let x = x2 - q * x1
    egcd_go(r, u, x, x1)
  }
}
