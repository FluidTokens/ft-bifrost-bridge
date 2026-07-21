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

const n = 4194304

const blinding_factors = 6

const g1_generator_bytes =
  #"bbc622db0af03afbef1a7af93fe8556c58ac1b173f3a4ea105b974974f8c68c30faca94f8c63952694d79731a7d3f197"

const scalar_delta =
  from_int(0x8634d0aa021aaf843cab354fabb0062f6502437c6a09c006c083479590189d7)

const transcript_rep =
  from_bytes_little_endian(
    #"9bee74b8235e115ab883577563cf492103ab64092558f9d4068bee27a2361d66",
  )

const omega =
  from_bytes_little_endian(
    #"63338eb0ffa6e7c6ee9b38867cec8fe0bbd1b8fb108fd3f232aabc5a5e6abe0a",
  )

const omega_inv =
  from_bytes_little_endian(
    #"40f63d0a9d8340755ea0c4fbc2b539ccabf552a3d537fc4b51e379cb20f5892a",
  )

const barycentric_weight =
  from_bytes_little_endian(
    #"01040000ff039006ff4f6e09b48e5dccdeb741223bb744bda130007383a5ed73",
  )

const s_g2 =
  decompress_g2(
    #"8afe2380027a81ed2b0b956fdcc4fec6525e905e84902bb5b7fe4ba6124a6f1eb048ddba78b0ee898843fa8253bf7554181652302a4ed08232e0945a38ad56edb8b3e49daa7dfa7c43acc4dbcc381acff267e3be4b3768cfedb6f53c7472a0dc",
  )

const fixed_0 =
  #"4a1dfd9085c2a3b9ae3120570c50a50352132f17fcd25bae541c7cbcca3c567f8d33c98ae5f98940241f95c559c4d2a2"

const fixed_1 =
  #"e42f710d3ca274922f6e2574ac100109980081796aa992c8fca4d0d44c4628b02c5828c2796ec48ec0c17eade800c6ad"

const fixed_2 =
  #"09f025e821202127a6562426d87ec3c1620a571747217afad01a096110e7f87f311a4cde848c85d9eaf64a92413755b4"

const fixed_3 =
  #"0f8c041330e49e4b394e9e462fe69856025931606525ab2212f85c87b18c9f7292062231b939079557ec84c92e3f2e82"

const permutation_common_0 =
  #"d5c8b945c37bb5b6f95688579d313791f5423d8fe49c9abcf01d822a447a1ba2b9ce42382d40beadeefbf9e8f4d90fb1"

const permutation_common_1 =
  #"68618ff1b1e118cf8250de7b730c532a308e8ba126cd4f22254e0477a2c91387a4b37fd53e025b9a2e14e5098fa6fa86"

const permutation_common_2 =
  #"994aab9c1d607760e54b000814151fde7d88db704ed013fdbd4033a80ab129ba2307315de84a35c306209f2968ef8fa9"

const permutation_common_3 =
  #"fe1974ce73e65bcaeef9353b95c199a03c41272b9b3bcc99fe6bf2602f0a9932d923946d03d15c2963d7816aacce5882"

const permutation_common_4 =
  #"b099a02300321b95323e4ce48e0d3daafeb72f126034f1f6b73a9a566991222f2cccf2a2f5c824f802ac52839bf5ef99"

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
