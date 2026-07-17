use aiken/collection/list.{foldl, map, zip}
use aiken/crypto/bitwise.{State}
use aiken/crypto/bls12_381/g1.{
  add as add_g1, decompress, scale as scale_g1, zero as zero_g1,
}
use aiken/crypto/bls12_381/g2.{
  decompress as decompress_g2, generator as generator_g2,
}
use aiken/crypto/bls12_381/pairing.{final_exponentiation, miller_loop}
use aiken/crypto/bls12_381/scalar.{
  Scalar, add, from_bytes_little_endian, from_int, mul, neg, scale as scalar_pow,
  sub, sub_int,
}
use aiken/primitive/bytearray
use bifrost/fault_verifier/halo2/bls_utils.{MSM, MSMElement, add_msm, recip_eea}
use bifrost/fault_verifier/halo2/lagrange.{
  batch_inverses, lagrange_polynomial_basis,
}
use bifrost/fault_verifier/halo2/omega_rotations.{rotate_omega, rotate_omegas}
use bifrost/fault_verifier/halo2/transcript.{
  common_scalar, construct_transcript, read_point, read_scalar,
  squeeze_challenge,
}

const n = 262144

const blinding_factors = 6

const g1_generator_bytes =
  #"bbc622db0af03afbef1a7af93fe8556c58ac1b173f3a4ea105b974974f8c68c30faca94f8c63952694d79731a7d3f197"

const scalar_delta =
  from_int(0x8634d0aa021aaf843cab354fabb0062f6502437c6a09c006c083479590189d7)

const transcript_rep =
  from_bytes_little_endian(
    #"5332fc88e345d6fbf3429eb56ace82b07a17c5cc845bd129dd2eba7162964f41",
  )

const omega =
  from_bytes_little_endian(
    #"fb74f68e7d1a426ffd40ce30bfa397bbb04bc3e17a712f65014f7930a556302d",
  )

const omega_inv =
  from_bytes_little_endian(
    #"d311d9268124b95233a8d6bba0c858e37985de51e3e06f70288100f4d31eb711",
  )

const barycentric_weight =
  from_bytes_little_endian(
    #"01400000ff3f0069ff9bfd96134fbcdd9cd59f9339cbe7d3e0b2c8bf578aed73",
  )

const s_g2 =
  decompress_g2(
    #"8afe2380027a81ed2b0b956fdcc4fec6525e905e84902bb5b7fe4ba6124a6f1eb048ddba78b0ee898843fa8253bf7554181652302a4ed08232e0945a38ad56edb8b3e49daa7dfa7c43acc4dbcc381acff267e3be4b3768cfedb6f53c7472a0dc",
  )

const fixed_0 =
  #"d11ca0417f5686a664b311bd33cefa06fb2299390162cd2920a7284e74174d5b1bb0e6fb6ad7af12da91cdfb900dbfa7"

const fixed_1 =
  #"2f87bc23d4821232bc7a6b88902ea0addbc9d2bd1bab3000f61a0d08019184f628859ebfec469a2945bbf09472dcefa4"

const fixed_2 =
  #"4b47c56fec6465007aab949bf1e8526e94ccac912f37bcccb3f27992798862ae5dde262d8ef3b25f3d40499d1bd55d93"

const fixed_3 =
  #"49dc441ae13a562daf779e579c171281ad3f1e9f2eee210b6c833320229f2d7460ea54ef1a2a385b873fa6fba4fa3e96"

const permutation_common_0 =
  #"40b5e2ba5f26ec5bf47f0fd436573392594bb6b4a0a37fe63e2519c8abb4c9fb7ef6b263ace86f49857933f51c4bc185"

const permutation_common_1 =
  #"6e3e65c8dd480c7ccea28bf72639e8e39c058382f0b0206e037dd7bc70d63d6db63a59c65aed85199ee908c25733f482"

const permutation_common_2 =
  #"1fbf0ec3845b487a951b2b9de454683ca8ac13f66a8c0c3c5707bd96838afe14cb6bd0510a63e15f7f51fcd0f04fe886"

const permutation_common_3 =
  #"92ecf7324e43b1c9fe897f5b5a9dee6dc59d4b35352de9911196a379216330bff5473d861746c955c77e6410d6799d90"

const permutation_common_4 =
  #"ceb90f8c15be9597dc39d45f3618d146f4c7f4334eaf52381c69d33acc8df947cde54cd6157a3f785d72fe1644c11691"

pub type ProofPieces {
  advice_0: ByteArray,
  advice_1: ByteArray,
  advice_2: ByteArray,
  theta: State<Scalar>,
  lookup_0_permuted_input: ByteArray,
  lookup_0_permuted_table: ByteArray,
  beta: State<Scalar>,
  gamma: State<Scalar>,
  permutation_product_0: ByteArray,
  permutation_product_1: ByteArray,
  permutation_product_2: ByteArray,
  lookup_0_product: ByteArray,
  random_poly: ByteArray,
  plonk_y: State<Scalar>,
  h_0: ByteArray,
  h_1: ByteArray,
  h_2: ByteArray,
  x: State<Scalar>,
  advice_eval_0: State<Scalar>,
  advice_eval_1: State<Scalar>,
  advice_eval_2: State<Scalar>,
  advice_eval_3: State<Scalar>,
  advice_eval_4: State<Scalar>,
  advice_eval_5: State<Scalar>,
  advice_eval_6: State<Scalar>,
  advice_eval_7: State<Scalar>,
  advice_eval_8: State<Scalar>,
  fixed_eval_0: State<Scalar>,
  fixed_eval_1: State<Scalar>,
  fixed_eval_2: State<Scalar>,
  fixed_eval_3: State<Scalar>,
  random_eval: State<Scalar>,
  permutation_common_eval_0: State<Scalar>,
  permutation_common_eval_1: State<Scalar>,
  permutation_common_eval_2: State<Scalar>,
  permutation_common_eval_3: State<Scalar>,
  permutation_common_eval_4: State<Scalar>,
  permutation_eval_0: State<Scalar>,
  permutation_next_0: State<Scalar>,
  permutation_last_0: State<Scalar>,
  permutation_eval_1: State<Scalar>,
  permutation_next_1: State<Scalar>,
  permutation_last_1: State<Scalar>,
  permutation_eval_2: State<Scalar>,
  permutation_next_2: State<Scalar>,
  lookup_0_product_eval: State<Scalar>,
  lookup_0_product_next: State<Scalar>,
  lookup_0_input_eval: State<Scalar>,
  lookup_0_input_prev_eval: State<Scalar>,
  lookup_0_table_eval: State<Scalar>,
  shplonk_y: State<Scalar>,
  v: State<Scalar>,
  shplonk_h1: ByteArray,
  u: State<Scalar>,
  shplonk_h2: ByteArray,
}

pub type Opening {
  msm: MSM,
  evals: List<State<Scalar>>,
}

pub fn verifier(proof: Data, public_inputs_raw: List<State<Scalar>>) -> Bool {
  when public_inputs_raw is {
    [_, _] -> {
      let p = parse_proof(proof, public_inputs_raw)
      let expected_h = expected_h_eval(p, public_inputs_raw)
      shplonk_pairing_check(p, expected_h)
    }
    _ -> False
  }
}

fn parse_proof(proof: Data, public_inputs: List<State<Scalar>>) -> ProofPieces {
  let transcript = construct_transcript(proof, transcript_rep)
  let transcript = foldl(
    public_inputs,
    transcript,
    fn(input, transcript) { common_scalar(input, transcript) },
  )
  let (advice_0, transcript) = read_point(transcript)
  let (advice_1, transcript) = read_point(transcript)
  let (advice_2, transcript) = read_point(transcript)
  let (theta, transcript) = squeeze_challenge(transcript)
  let (lookup_0_permuted_input, transcript) = read_point(transcript)
  let (lookup_0_permuted_table, transcript) = read_point(transcript)
  let (beta, transcript) = squeeze_challenge(transcript)
  let (gamma, transcript) = squeeze_challenge(transcript)
  let (permutation_product_0, transcript) = read_point(transcript)
  let (permutation_product_1, transcript) = read_point(transcript)
  let (permutation_product_2, transcript) = read_point(transcript)
  let (lookup_0_product, transcript) = read_point(transcript)
  let (random_poly, transcript) = read_point(transcript)
  let (plonk_y, transcript) = squeeze_challenge(transcript)
  let (h_0, transcript) = read_point(transcript)
  let (h_1, transcript) = read_point(transcript)
  let (h_2, transcript) = read_point(transcript)
  let (x, transcript) = squeeze_challenge(transcript)
  let (advice_eval_0, transcript) = read_scalar(transcript)
  let (advice_eval_1, transcript) = read_scalar(transcript)
  let (advice_eval_2, transcript) = read_scalar(transcript)
  let (advice_eval_3, transcript) = read_scalar(transcript)
  let (advice_eval_4, transcript) = read_scalar(transcript)
  let (advice_eval_5, transcript) = read_scalar(transcript)
  let (advice_eval_6, transcript) = read_scalar(transcript)
  let (advice_eval_7, transcript) = read_scalar(transcript)
  let (advice_eval_8, transcript) = read_scalar(transcript)
  let (fixed_eval_0, transcript) = read_scalar(transcript)
  let (fixed_eval_1, transcript) = read_scalar(transcript)
  let (fixed_eval_2, transcript) = read_scalar(transcript)
  let (fixed_eval_3, transcript) = read_scalar(transcript)
  let (random_eval, transcript) = read_scalar(transcript)
  let (permutation_common_eval_0, transcript) = read_scalar(transcript)
  let (permutation_common_eval_1, transcript) = read_scalar(transcript)
  let (permutation_common_eval_2, transcript) = read_scalar(transcript)
  let (permutation_common_eval_3, transcript) = read_scalar(transcript)
  let (permutation_common_eval_4, transcript) = read_scalar(transcript)
  let (permutation_eval_0, transcript) = read_scalar(transcript)
  let (permutation_next_0, transcript) = read_scalar(transcript)
  let (permutation_last_0, transcript) = read_scalar(transcript)
  let (permutation_eval_1, transcript) = read_scalar(transcript)
  let (permutation_next_1, transcript) = read_scalar(transcript)
  let (permutation_last_1, transcript) = read_scalar(transcript)
  let (permutation_eval_2, transcript) = read_scalar(transcript)
  let (permutation_next_2, transcript) = read_scalar(transcript)
  let (lookup_0_product_eval, transcript) = read_scalar(transcript)
  let (lookup_0_product_next, transcript) = read_scalar(transcript)
  let (lookup_0_input_eval, transcript) = read_scalar(transcript)
  let (lookup_0_input_prev_eval, transcript) = read_scalar(transcript)
  let (lookup_0_table_eval, transcript) = read_scalar(transcript)
  let (shplonk_y, transcript) = squeeze_challenge(transcript)
  let (v, transcript) = squeeze_challenge(transcript)
  let (shplonk_h1, transcript) = read_point(transcript)
  let (u, transcript) = squeeze_challenge(transcript)
  let (shplonk_h2, _transcript) = read_point(transcript)
  ProofPieces {
    advice_0,
    advice_1,
    advice_2,
    theta,
    lookup_0_permuted_input,
    lookup_0_permuted_table,
    beta,
    gamma,
    permutation_product_0,
    permutation_product_1,
    permutation_product_2,
    lookup_0_product,
    random_poly,
    plonk_y,
    h_0,
    h_1,
    h_2,
    x,
    advice_eval_0,
    advice_eval_1,
    advice_eval_2,
    advice_eval_3,
    advice_eval_4,
    advice_eval_5,
    advice_eval_6,
    advice_eval_7,
    advice_eval_8,
    fixed_eval_0,
    fixed_eval_1,
    fixed_eval_2,
    fixed_eval_3,
    random_eval,
    permutation_common_eval_0,
    permutation_common_eval_1,
    permutation_common_eval_2,
    permutation_common_eval_3,
    permutation_common_eval_4,
    permutation_eval_0,
    permutation_next_0,
    permutation_last_0,
    permutation_eval_1,
    permutation_next_1,
    permutation_last_1,
    permutation_eval_2,
    permutation_next_2,
    lookup_0_product_eval,
    lookup_0_product_next,
    lookup_0_input_eval,
    lookup_0_input_prev_eval,
    lookup_0_table_eval,
    shplonk_y,
    v,
    shplonk_h1,
    u,
    shplonk_h2,
  }
}

fn expected_h_eval(
  p: ProofPieces,
  public_inputs: List<State<Scalar>>,
) -> State<Scalar> {
  let scalar_zero = from_int(0)
  let scalar_one = from_int(1)
  let xn = scalar_pow(p.x, n)
  let rotations = rotate_omegas(omega, omega_inv, -(blinding_factors + 1), 0)
  let l_evals = lagrange_polynomial_basis(
    p.x,
    xn,
    barycentric_weight,
    rotations,
  )
  expect  
      [
        l_last, l_blind_0, l_blind_1, l_blind_2, l_blind_3, l_blind_4, l_blind_5,
        l_0,
      ]
    = l_evals
  let l_blind = add(
    add(add(add(add(l_blind_0, l_blind_1), l_blind_2), l_blind_3), l_blind_4),
    l_blind_5,
  )
  let active_rows = sub(scalar_one, add(l_last, l_blind))
  let instance_rotations = rotate_omegas(omega, omega_inv, 0, 1)
  let instance_lagrange = lagrange_polynomial_basis(
    p.x,
    xn,
    barycentric_weight,
    instance_rotations,
  )
  let instance_eval = weighted_sum(public_inputs, instance_lagrange)
  let gate_0 = mul(
    p.fixed_eval_2,
    add(
      add(p.advice_eval_0, mul(p.advice_eval_1, p.advice_eval_2)),
      neg(p.advice_eval_3),
    ),
  )
  let gate_1 = mul(
    p.fixed_eval_3,
    add(
      add(p.advice_eval_4, mul(p.advice_eval_5, p.advice_eval_6)),
      neg(p.advice_eval_7),
    ),
  )
  let perm_first = mul(l_0, sub(scalar_one, p.permutation_eval_0))
  let perm_last = mul(
    l_last,
    sub(mul(p.permutation_eval_2, p.permutation_eval_2), p.permutation_eval_2),
  )
  let perm_link_1 = mul(l_0, sub(p.permutation_eval_1, p.permutation_last_0))
  let perm_link_2 = mul(l_0, sub(p.permutation_eval_2, p.permutation_last_1))
  let perm_set_0 = mul(
    active_rows,
    sub(
      mul(
        mul(
          p.permutation_next_0,
          add(
            add(p.fixed_eval_0, mul(p.beta, p.permutation_common_eval_0)),
            p.gamma,
          ),
        ),
        add(
          add(p.advice_eval_0, mul(p.beta, p.permutation_common_eval_1)),
          p.gamma,
        ),
      ),
      mul(
        mul(
          p.permutation_eval_0,
          add(add(p.fixed_eval_0, mul(p.beta, p.x)), p.gamma),
        ),
        add(add(p.advice_eval_0, mul(mul(p.beta, p.x), scalar_delta)), p.gamma),
      ),
    ),
  )
  let perm_set_1 = mul(
    active_rows,
    sub(
      mul(
        mul(
          p.permutation_next_1,
          add(
            add(p.advice_eval_4, mul(p.beta, p.permutation_common_eval_2)),
            p.gamma,
          ),
        ),
        add(
          add(p.advice_eval_8, mul(p.beta, p.permutation_common_eval_3)),
          p.gamma,
        ),
      ),
      mul(
        mul(
          p.permutation_eval_1,
          add(
            add(
              p.advice_eval_4,
              mul(mul(p.beta, p.x), scalar_pow(scalar_delta, 2)),
            ),
            p.gamma,
          ),
        ),
        add(
          add(
            p.advice_eval_8,
            mul(mul(p.beta, p.x), scalar_pow(scalar_delta, 3)),
          ),
          p.gamma,
        ),
      ),
    ),
  )
  let perm_set_2 = mul(
    active_rows,
    sub(
      mul(
        p.permutation_next_2,
        add(
          add(instance_eval, mul(p.beta, p.permutation_common_eval_4)),
          p.gamma,
        ),
      ),
      mul(
        p.permutation_eval_2,
        add(
          add(instance_eval, mul(mul(p.beta, p.x), scalar_pow(scalar_delta, 4))),
          p.gamma,
        ),
      ),
    ),
  )
  let lookup_0_first = mul(l_0, sub(scalar_one, p.lookup_0_product_eval))
  let lookup_0_last = mul(
    l_last,
    sub(
      mul(p.lookup_0_product_eval, p.lookup_0_product_eval),
      p.lookup_0_product_eval,
    ),
  )
  let lookup_0_product_expression = mul(
    active_rows,
    sub(
      mul(
        mul(p.lookup_0_product_next, add(p.lookup_0_input_eval, p.beta)),
        add(p.lookup_0_table_eval, p.gamma),
      ),
      mul(
        mul(p.lookup_0_product_eval, add(p.advice_eval_8, p.beta)),
        add(p.fixed_eval_1, p.gamma),
      ),
    ),
  )
  let lookup_0_initial = mul(
    l_0,
    sub(p.lookup_0_input_eval, p.lookup_0_table_eval),
  )
  let lookup_0_adjacent = mul(
    mul(active_rows, sub(p.lookup_0_input_eval, p.lookup_0_table_eval)),
    sub(p.lookup_0_input_eval, p.lookup_0_input_prev_eval),
  )
  let folded = foldl(
    [
      gate_0, gate_1, perm_first, perm_last, perm_link_1, perm_link_2,
      perm_set_0, perm_set_1, perm_set_2, lookup_0_first, lookup_0_last,
      lookup_0_product_expression, lookup_0_initial, lookup_0_adjacent,
    ],
    scalar_zero,
    fn(expr, acc) { add(mul(acc, p.plonk_y), expr) },
  )
  mul(folded, recip_eea(sub_int(xn, 1)))
}

fn shplonk_pairing_check(p: ProofPieces, expected_h: State<Scalar>) -> Bool {
  let xn = scalar_pow(p.x, n)
  let x_current = p.x
  let x_rot_1 = rotate_omega(omega, omega_inv, p.x, 1)
  let x_rot_2 = rotate_omega(omega, omega_inv, p.x, 2)
  let x_rot_3 = rotate_omega(omega, omega_inv, p.x, 3)
  let x_rot_neg_7 = rotate_omega(omega, omega_inv, p.x, -7)
  let x_rot_neg_1 = rotate_omega(omega, omega_inv, p.x, -1)
  let z0 = vanishing([x_current, x_rot_1, x_rot_2, x_rot_3], p.u)
  let z0_diff_inv = recip_eea(vanishing([x_rot_neg_7, x_rot_neg_1], p.u))
  let (msm_0, r_0) = rotation_contribution(
    [x_current, x_rot_1, x_rot_2, x_rot_3],
    [
      point_opening(
        p.advice_0,
        [p.advice_eval_0, p.advice_eval_1, p.advice_eval_2, p.advice_eval_3],
      ),
      point_opening(
        p.advice_1,
        [p.advice_eval_4, p.advice_eval_5, p.advice_eval_6, p.advice_eval_7],
      ),
    ],
    p.u,
    p.shplonk_y,
    from_int(1),
    from_int(1),
  )
  let (msm_1, r_1) = rotation_contribution(
    [x_current],
    [
      point_opening(p.advice_2, [p.advice_eval_8]),
      point_opening(p.lookup_0_permuted_table, [p.lookup_0_table_eval]),
      point_opening(fixed_1, [p.fixed_eval_0]),
      point_opening(fixed_0, [p.fixed_eval_1]),
      point_opening(fixed_2, [p.fixed_eval_2]),
      point_opening(fixed_3, [p.fixed_eval_3]),
      point_opening(permutation_common_0, [p.permutation_common_eval_0]),
      point_opening(permutation_common_1, [p.permutation_common_eval_1]),
      point_opening(permutation_common_2, [p.permutation_common_eval_2]),
      point_opening(permutation_common_3, [p.permutation_common_eval_3]),
      point_opening(permutation_common_4, [p.permutation_common_eval_4]),
      Opening { msm: vanishing_h_msm(p, xn), evals: [expected_h] },
      point_opening(p.random_poly, [p.random_eval]),
    ],
    p.u,
    p.shplonk_y,
    p.v,
    mul(
      vanishing([x_rot_1, x_rot_2, x_rot_3, x_rot_neg_7, x_rot_neg_1], p.u),
      z0_diff_inv,
    ),
  )
  let (msm_2, r_2) = rotation_contribution(
    [x_rot_neg_7, x_current, x_rot_1],
    [
      point_opening(
        p.permutation_product_0,
        [p.permutation_last_0, p.permutation_eval_0, p.permutation_next_0],
      ),
      point_opening(
        p.permutation_product_1,
        [p.permutation_last_1, p.permutation_eval_1, p.permutation_next_1],
      ),
    ],
    p.u,
    p.shplonk_y,
    scalar_pow(p.v, 2),
    mul(vanishing([x_rot_2, x_rot_3, x_rot_neg_1], p.u), z0_diff_inv),
  )
  let (msm_3, r_3) = rotation_contribution(
    [x_current, x_rot_1],
    [
      point_opening(
        p.permutation_product_2,
        [p.permutation_eval_2, p.permutation_next_2],
      ),
      point_opening(
        p.lookup_0_product,
        [p.lookup_0_product_eval, p.lookup_0_product_next],
      ),
    ],
    p.u,
    p.shplonk_y,
    scalar_pow(p.v, 3),
    mul(
      vanishing([x_rot_2, x_rot_3, x_rot_neg_7, x_rot_neg_1], p.u),
      z0_diff_inv,
    ),
  )
  let (msm_4, r_4) = rotation_contribution(
    [x_rot_neg_1, x_current],
    [
      point_opening(
        p.lookup_0_permuted_input,
        [p.lookup_0_input_prev_eval, p.lookup_0_input_eval],
      ),
    ],
    p.u,
    p.shplonk_y,
    scalar_pow(p.v, 4),
    mul(vanishing([x_rot_1, x_rot_2, x_rot_3, x_rot_neg_7], p.u), z0_diff_inv),
  )
  let outer_msm = foldl(
    [msm_0, msm_1, msm_2, msm_3, msm_4],
    MSM { elements: [] },
    fn(msm, acc) { add_msm(acc, msm) },
  )
  let r_outer = foldl(
    [r_0, r_1, r_2, r_3, r_4],
    from_int(0),
    fn(r, acc) { add(acc, r) },
  )
  let outer_msm = add_msm(
    outer_msm,
    MSM {
      elements: [
        MSMElement { scalar: neg(r_outer), g1: g1_generator_bytes },
        MSMElement { scalar: neg(z0), g1: p.shplonk_h1 },
        MSMElement { scalar: p.u, g1: p.shplonk_h2 },
      ],
    },
  )
  final_exponentiation(
    miller_loop(axiom_decompress_g1(p.shplonk_h2), s_g2),
    miller_loop(eval_axiom_msm(outer_msm), generator_g2),
  )
}

fn rotation_contribution(
  points: List<State<Scalar>>,
  openings: List<Opening>,
  u: State<Scalar>,
  y: State<Scalar>,
  v_power: State<Scalar>,
  z_diff: State<Scalar>,
) -> (MSM, State<Scalar>) {
  let basis = lagrange_basis_at(points, u)
  let factor = mul(v_power, z_diff)
  let (inner_msm, r_inner) = rotation_contribution_go(
    openings,
    basis,
    y,
    factor,
    from_int(1),
    MSM { elements: [] },
    from_int(0),
  )
  (inner_msm, mul(factor, r_inner))
}

fn rotation_contribution_go(
  openings: List<Opening>,
  basis: List<State<Scalar>>,
  y: State<Scalar>,
  factor: State<Scalar>,
  y_power: State<Scalar>,
  msm_acc: MSM,
  r_acc: State<Scalar>,
) -> (MSM, State<Scalar>) {
  when openings is {
    [] -> (msm_acc, r_acc)
    [opening, ..rest] -> {
      let r_eval = weighted_sum(opening.evals, basis)
      rotation_contribution_go(
        rest,
        basis,
        y,
        factor,
        mul(y_power, y),
        add_scaled_msm(msm_acc, mul(factor, y_power), opening.msm),
        add(r_acc, mul(y_power, r_eval)),
      )
    }
  }
}

fn add_scaled_msm(acc: MSM, scalar: State<Scalar>, msm: MSM) -> MSM {
  MSM { elements: add_scaled_elements(msm.elements, scalar, acc.elements) }
}

fn add_scaled_elements(
  elements: List<MSMElement>,
  scalar: State<Scalar>,
  acc: List<MSMElement>,
) -> List<MSMElement> {
  when elements is {
    [] -> acc
    [element, ..rest] ->
      add_scaled_elements(
        rest,
        scalar,
        [
          MSMElement { scalar: mul(scalar, element.scalar), g1: element.g1 },
          ..acc
        ],
      )
  }
}

fn lagrange_basis_at(
  points: List<State<Scalar>>,
  x: State<Scalar>,
) -> List<State<Scalar>> {
  when points is {
    [] -> []
    [_] -> [from_int(1)]
    _ -> {
      let basis_data = map(
        points,
        fn(xi) {
          foldl(
            points,
            (from_int(1), from_int(1)),
            fn(xj, (num, denom)) {
              if xj == xi {
                (num, denom)
              } else {
                (mul(num, sub(x, xj)), mul(denom, sub(xi, xj)))
              }
            },
          )
        },
      )
      let inverted_denominators = batch_inverses(
        map(basis_data, fn((_, denom)) { denom }),
      )
      map(
        zip(basis_data, inverted_denominators),
        fn(((num, _), denom_inv)) { mul(num, denom_inv) },
      )
    }
  }
}

fn weighted_sum(
  evals: List<State<Scalar>>,
  basis: List<State<Scalar>>,
) -> State<Scalar> {
  foldl(
    zip(evals, basis),
    from_int(0),
    fn((eval, basis), acc) { add(acc, mul(eval, basis)) },
  )
}

fn point_opening(point: ByteArray, evals: List<State<Scalar>>) -> Opening {
  Opening { msm: point_msm(point), evals }
}

fn point_msm(point: ByteArray) -> MSM {
  MSM { elements: [MSMElement { scalar: from_int(1), g1: point }] }
}

fn vanishing_h_msm(p: ProofPieces, xn: State<Scalar>) -> MSM {
  MSM {
    elements: [
      MSMElement { scalar: from_int(1), g1: p.h_0 },
      MSMElement { scalar: xn, g1: p.h_1 },
      MSMElement { scalar: scalar_pow(xn, 2), g1: p.h_2 },
    ],
  }
}

fn vanishing(points: List<State<Scalar>>, u: State<Scalar>) -> State<Scalar> {
  foldl(points, from_int(1), fn(point, acc) { mul(acc, sub(u, point)) })
}

fn eval_axiom_msm(msm: MSM) -> G1Element {
  foldl(
    msm.elements,
    zero_g1,
    fn(element, acc) {
      add_g1(acc, scale_g1(axiom_decompress_g1(element.g1), element.scalar))
    },
  )
}

fn axiom_decompress_g1(bytes: ByteArray) -> G1Element {
  decompress(reverse_bytes(bytes))
}

fn reverse_bytes(bytes: ByteArray) -> ByteArray {
  bytearray.foldl(bytes, #"", fn(byte, acc) { bytearray.push(acc, byte) })
}
