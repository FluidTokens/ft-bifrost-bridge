use aiken/collection/list.{foldl, map, reverse, zip}
use aiken/crypto/bitwise.{State}
use aiken/crypto/bls12_381/scalar.{Scalar, add, from_int, mul, sub, sub_int}
use bifrost/fault_verifier/halo2/bls_utils.{recip_eea}

// TODO: Revert to this version of lagrange_evaluation when CIP-109 with built-in inverse is available, because it will be faster than batch_inverses
// fn lagrange_evaluation(
//   points: List<(State<Scalar>, State<Scalar>)>,
//   x: State<Scalar>,
// ) -> State<Scalar> {
//   foldl(
//     points,
//     from_int(0),
//     fn((xi, yi), acc) { add(acc, mul(yi, basis(x, xi, points))) },
//   )
// }

// fn basis(
//   x: State<Scalar>,
//   xi: State<Scalar>,
//   points: List<(State<Scalar>, State<Scalar>)>,
// ) -> State<Scalar> {
//   let (total_numerator, total_denominator) =
//     foldl(
//       points,
//       (from_int(1), from_int(1)),
//       fn((xj, _), (numerator, denominator)) {
//         if !(xj == xi) {
//           (mul(numerator, sub(x, xj)), mul(denominator, sub(xi, xj)))
//         } else {
//           (numerator, denominator)
//         }
//       },
//     )
//   let total_denominator = recip_eea(total_denominator)
//   mul(total_numerator, total_denominator)
// }

// Optimized lagrange_evaluation using batch_inverses
pub fn lagrange_evaluation(
  points: List<(State<Scalar>, State<Scalar>)>,
  x: State<Scalar>,
) -> State<Scalar> {
  // Step 1: Compute all (numerator, denominator, yi) tuples
  let basis_data = map(
    points,
    fn((xi, yi)) {
      let (num, denom) = foldl(
        points,
        (from_int(1), from_int(1)),
        fn((xj, _), (numerator, denominator)) {
          if xj == xi {
            (numerator, denominator)
          } else {
            (mul(numerator, sub(x, xj)), mul(denominator, sub(xi, xj)))
          }
        },
      )
      (num, denom, yi)
    },
  )

  // Step 2: Extract denominators and batch invert (1 recip instead of N!)
  let denominators = map(basis_data, fn((_, denom, _)) { denom })
  let inverted_denominators = batch_inverses(denominators)

  // Step 3: Compute final sum
  foldl(
    zip(basis_data, inverted_denominators),
    from_int(0),
    fn(((num, _, yi), denom_inv), acc) {
      add(acc, mul(yi, mul(num, denom_inv)))
    },
  )
}

pub fn lagrange_polynomial_basis(
  x: State<Scalar>,
  xn: State<Scalar>,
  barycentric_weight: State<Scalar>,
  rotations: List<State<Scalar>>,
) -> List<State<Scalar>> {
  let common = mul(sub_int(xn, 1), barycentric_weight)
  // TODO: when CIP-109 is implemented and built-in inversion is available, replace batch_inverses as follows
  // let inverses =
  //   map(
  //     rotations,
  //     fn(rotated_omega) { recip(sub(x, rotated_omega)) },
  //   )
  let inverses = batch_inverses(
    map(rotations, fn(rotated_omega) { sub(x, rotated_omega) }),
  )
  let zipped = zip(inverses, rotations)
  map(zipped, fn((inv, rotated_omega)) { mul(mul(inv, common), rotated_omega) })
}

pub fn batch_inverses(elements: List<State<Scalar>>) -> List<State<Scalar>> {
  when elements is {
    [] -> []
    [a, ..a_cons] -> {
      // Build reversed cumulative products
      let b_rev = foldl(
        a_cons,
        [a],
        fn(elem, accum) {
          expect [head_accum, ..] = accum
          [mul(elem, head_accum), ..accum]
        },
      )

      let a_rev = reverse(elements)

      expect [head_b_rev, ..tail_b_rev] = b_rev
      let b_inv_last = recip_eea(head_b_rev)

      let (a_inv_acc, b_inv_1) = foldl(
        zip(tail_b_rev, a_rev),
        ([], b_inv_last),
        fn((b_i_min_1, a_i), (a_inv_accum, b_inv_i)) {
          ([mul(b_inv_i, b_i_min_1), ..a_inv_accum], mul(b_inv_i, a_i))
        },
      )

      [b_inv_1, ..a_inv_acc]
    }
  }
}
