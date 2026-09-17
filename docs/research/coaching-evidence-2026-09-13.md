# Coaching evidence review — what measurably improves basketball shooting, and what supports feeding it back

Date: 2026-09-13. Scope: sources for the findings engine (`docs/BRIEF.md` §6) and the drill layer.
Method: 24 web searches; primary sources fetched where open (PMC, Europe PMC, bioRxiv, PeerJ, author
PDFs, Frontiers, JSSM); paywalled abstracts read via Europe PMC/Semantic Scholar. Numbers are quoted
as the source states them. Anything I could not open is marked **UNVERIFIED**. Already-known material
(32.06° entry floor, Noah "45/11", Wulf / McKay 2022–2024, regression to the mean, one change at a
time, the dip/back-off rule) lives in `docs/reference/digest-ch15-16-engine.md` and
`digest-ch17-18-delivery-report.md` and is not repeated here except where a new source sharpens it.

## Summary — the five things worth feeding back, ranked by evidence

1. **Release-speed consistency (SD of release speed within a cell).** The single strongest published
   correlate of shooting percentage: in 12 skilled shooters, release-velocity SD correlated r = −0.96
   with 3-point performance and r = −0.88 with free-throw performance, whereas release-angle SD was
   weak (r = −0.41, p = 0.19 at 3-pt) (Slegers, Lee & Wong 2021). Misses at the line release
   −0.12 ± 0.10 m/s below optimal vs −0.02 ± 0.07 for swishes (Mullineaux & Uhl 2010). Depth at the
   rim is the observable consequence, so *depth SD* is the coachable proxy when speed is not tier A.
2. **Depth at the rim and its make/miss separation.** NBA SportVU data: 3-point make probability is
   highest at 11″ depth and 0″ left-right; shots landing 9″ deep are made 60.1 %, 10″ deep 64.5 %;
   tight contests bias shots *short* and raise depth variance 56 % (Daly-Grafstein & Bornn 2019,
   2020; consistent with Marty & Lucey 2017's 1.1 M-shot Noah dataset). Short-miss bias is the one
   directional claim with a large-n published anchor.
3. **Entry angle — as a within-player make/miss discriminator, not an absolute target.** Make
   probability peaks in the "mid-40s" but is "more consistent over a range of entry angles compared
   to either left-right distance or shot depth" (Daly-Grafstein & Bornn 2020). Higher-level U18
   players had entry angles closer to 45° (p = 0.006) and faster releases (p = 0.002) (Botsi et al.
   2024). Individual optimal *release* angles vary between shooters and sit 4.3 ± 2.1° above the
   minimum-velocity angle (Slegers 2022) — so the engine should test the player's own separation.
4. **Within-session drift under fatigue (entry angle, release height, release time).** After a
   12-min simulated-game protocol, 38 high-level players' entry angle fell −3.1 to −3.9 %, release
   time rose +15 to +25 %, and makes fell −14 to −19 % (Bourdas et al. 2024). Meta-analysis of 14
   studies (n = 388): moderate physical fatigue SMD 0.67 [0.24, 1.10], severe 1.39 [0.76, 2.01] on
   accuracy (Li et al. 2025). But elite U18s showed *no* release change after repeated sprints
   (Slawinski et al. 2018) — drift must be measured, not assumed.
5. **Left-right deviation (frontal views only), especially its variance.** SD of spin-axis alignment
   predicted lateral accuracy (r = 0.80 for vertical-axis SD) while *mean* misalignment did not
   (Slegers & Love 2022); NBA contests raise left-right variance 38 % without biasing direction
   (Daly-Grafstein & Bornn 2020). Consistency, not a mean offset, is the signal.

Honourable mentions with weaker or between-subject evidence: elbow flare / forearm angle (Cabarkapa
& Fry 2021), preparatory-phase knee depth and knee angular velocity (Cabarkapa 2023, 2026), the
"dip" (Penner 2021), release height (direction of effect is inconsistent across studies). Quiet-eye
training has large published effects but is invisible to a tripod camera; it belongs in the drill
layer only.

## Evidence table

| Metric | What the evidence says | Effect size / numbers | Population | Source | Provenance for rules | Quality caveat |
|---|---|---|---|---|---|---|
| Release-speed SD | Velocity variability predicts shooting performance; angle variability barely does | Velocity SD: FT 0.086 ± 0.016 m/s, 3-pt 0.089 ± 0.025 m/s (range 0.05–0.13); r = −0.96 (3-pt), −0.88 (FT). Angle SD: 1.3 ± 0.26° FT, 1.2 ± 0.24° 3-pt; r = −0.69 (FT, p = 0.02), −0.41 (3-pt, p = 0.19) | 12 skilled males (6 secondary, 6 collegiate; FT 79 ± 11 %), 75 3-pt + 50 FT each, 60 fps video + drag trajectory fit | [Slegers, Lee & Wong 2021, JSSM](https://pmc.ncbi.nlm.nih.gov/articles/PMC8256521/) | published | n = 12; correlation across shooters, not within; method is video trajectory fit — same measurement class as ArcLab (good for transfer) |
| Release speed vs optimum | Misses release slower than optimal speed; coordination variability spikes 0.01 s before release on misses | misses −0.12 ± 0.10 m/s vs swishes −0.02 ± 0.07 m/s below optimal, p < 0.05 | Collegiate players, 20 FTs each, 3 misses + 3 swishes analysed | [Mullineaux & Uhl 2010, J Sports Sci](https://pubmed.ncbi.nlm.nih.gov/20552519/) | published | tiny per-subject samples (3 vs 3); swish-only "makes" |
| Release angle relative to minimum-speed angle | Skilled shooters choose an angle just above the minimum-speed angle; individual optima differ | Nakano: deviation from min-speed angle 2.8 ± 3.1°; predicted vs measured success r = 0.70. Slegers: optimal 4.3 ± 2.1° above min-velocity; mean release 3.9° above min-velocity and 0.4° below individual optimum (p = 0.5); optimum correlates with individual release-PDF covariance r = 0.78 | 8 collegiate (65 ± 15 % FT) + 1 pro (99 %); 16 males, 75 3-pt each | [Nakano et al. 2020, Hum Mov Sci (bioRxiv full text)](https://www.biorxiv.org/content/10.1101/793513v1.full); [Slegers 2022, IJPAS](https://digitalcommons.georgefox.edu/mece_fac/129/) | published | Both small n; min-speed angle is pure geometry (release height, distance), so the *reference* is computable per shot |
| Entry angle | Make probability peaks in the mid-40s but is flat over a range; higher-level juniors closer to 45° | NBA: mean entry ≈ 45°; make prob. "more consistent over a range of entry angles compared to either left-right distance or shot depth". U18: HL entry angle "closer-to-optimal 45° (8.1 %)", t(77) = 2.856, p = 0.006 | 47,631 3-pt shots (2014–15) + 49,876 (2015–16), SportVU; 79 U18 males (38 HL / 41 LL) | [Daly-Grafstein & Bornn 2019, JQAS (PDF)](https://www.lukebornn.com/papers/dalygrafstein_jqas_2019.pdf); [Daly-Grafstein & Bornn 2020, JSA (PDF)](https://www.lukebornn.com/papers/dalygrafstein_jsa_2020.pdf); [Botsi et al. 2024, JFMK](https://pmc.ncbi.nlm.nih.gov/articles/PMC11677033/) | published | NBA entry angles are model-estimated from 25 Hz tracking (their GMZ shots made 85.2 % vs Noah's >90 %, i.e. noisier); Botsi gives no effect size |
| Depth at rim | Deeper than centre is better; contests bias short and inflate depth variance | Highest make prob. at 11″ depth (centre = 9″); 9″ made 60.1 %, 10″ made 64.5 %; "shot depths between 10″ and 11″ maximize 3P%"; tightly contested (<4 ft) vs open (>6 ft): +56 % depth variance, +38 % left-right variance; contest biases short, not left/right | >50,000 NBA 3-pt trajectories, 2014–15 | [Daly-Grafstein & Bornn 2020, JSA](https://journals.sagepub.com/doi/10.3233/JSA-200400) (PDF above) | published | NBA-only; depth estimated, not measured; game shots, not practice |
| Left-right deviation | Lateral *consistency* is predicted by spin-axis consistency; mean misalignment irrelevant; NBA contests do not bias direction | Vertical spin-axis SD vs lateral accuracy r = 0.80 (p < 0.001); forward-backward SD r = 0.51 (p = 0.01); mean misalignment n.s. | 26 collegiate (16 M / 10 F), 25 shots each | [Slegers & Love 2022, J Sports Sci](https://pubmed.ncbi.nlm.nih.gov/35611914/) | published | ArcLab cannot measure spin; only the lateral outcome. Cross-sectional |
| Release angle by distance | Release angle falls and speed rises with distance | 52–55° at 2.74/4.57 m, 48–50° at 6.40 m; earlier release timing with distance | 15 males (5 G / 5 F / 5 C), 3D film 100 Hz | [Miller & Bartlett 1996, J Sports Sci](https://pubmed.ncbi.nlm.nih.gov/8809716/) | published | 1996, n = 15; justifies bucketing by distance, not a target |
| Release angle by distance (pros) | Same pattern in professionals; *no* kinematic difference between excellent and good shooters | FT 60.8 ± 6.3°, 2-pt 58.9 ± 7.4°, 3-pt 56.9 ± 8.5° (p = 0.003); vertical displacement 15.3 / 26.9 / 31.2 cm | 10 professional males | [Cabarkapa et al. 2022, JFMK](https://pmc.ncbi.nlm.nih.gov/articles/PMC9590067/) | published | n = 10; the null result on proficiency is itself a caution against absolute targets |
| Release angle / elbow at release, made vs missed | Within proficient female shooters, 3-pt makes had smaller elbow angle and higher release angle | Elbow 47.0° made vs 53.0° missed (p = 0.013); release angle 42.0° vs 38.0° (p = 0.020); 2-pt: hip 137.0° vs 133.0° (p = 0.048) | 18 recreationally active females | [Cabarkapa et al. 2023, JFMK](https://pmc.ncbi.nlm.nih.gov/articles/PMC10531893/) | published | Small n; 2D video; direction may not generalise |
| Made vs missed jump shots (male) | Makes: higher elbow in set, more erect torso, greater release angle, greater jump height at release, higher apex | Qualitative in abstract; numeric tables not retrievable (403) — **UNVERIFIED numbers** | 29 recreationally active males, 580 shots | [Cabarkapa et al. 2022, Biomechanics](https://www.mdpi.com/2673-7078/2/3/28) | published (direction only) | Recreational shooters; apex height and release angle are ArcLab tier-1 metrics |
| Elbow flare (forearm angle from vertical) | Proficient FT shooters had far smaller lateral forearm angle; it was the variable separating made/missed within proficient | Forearm angle 7.9 ± 7.2° vs 19.8 ± 17.6°; elbow angle 71.9 ± 5.6° vs 80.5 ± 6.3°; knee flexion 108.5 ± 9.8° vs 117.9 ± 16.3°; DFA classifies 89.5 % | 17 recreationally active males, 495 FTs; proficient 82.7 ± 7.9 % vs 52.4 ± 13.4 % | [Cabarkapa & Fry et al. 2021, CEJSSM (PDF)](https://wnus.usz.edu.pl/cejssm/file/article/download/19306/78716.pdf) | published | 17 sensors at 60 Hz; between-group; frontal-plane metric — requires a frontal view class |
| Preparatory-phase knee / COM control | Proficient FT shooters move slower and lower; proficient 3-pt shooters load deeper — and show *no* release-phase differences | FT: knee peak ang. vel. 269.4 vs 212.9 °/s (p = 0.005, ES 1.037); COM peak vel. 1.07 vs 0.87 m/s (ES 0.988); trunk lean 1.87 vs −1.11° (ES 0.880); release angle 52.1 ± 5.4 vs 51.4 ± 3.2 n.s. 3-pt: knee 113.2° vs 94.3° (ES 3.961); hip 155.9° vs 143.1°; stance 27.4 vs 34.3 cm; release height 1.19 vs 1.20, jump 23.7 vs 25.8 cm n.s. | 34 males (19 proficient ≥70 %); 24 males (11 proficient ≥50 %); markerless 120 Hz | [Cabarkapa et al. 2023, Front Sports Act Living](https://pmc.ncbi.nlm.nih.gov/articles/PMC10436204/); [Cabarkapa, Cabarkapa & Fry 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC12935449/) | published | Recreational; between-group; ES 3.96 is implausibly large for a knee angle — treat as direction only |
| Release height | Direction is inconsistent | Wang 2026: made 2.28 ± 0.06 m vs missed 2.19 ± 0.07 m (d = 1.85). Cabarkapa 2023: within proficient, *missed* FTs had higher release (1.19 vs 1.17, p = 0.035, ES 0.161). Amaro 2025: ρ = 0.116 (p = 0.002), η²p < 0.01 | 50 (25 athletes / 25 novices); 34 males; 18 national-level (710 shots) | [Wang et al. 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC13291941/); [Cabarkapa 2023](https://pmc.ncbi.nlm.nih.gov/articles/PMC10436204/); [Amaro et al. 2025, JFMK](https://pmc.ncbi.nlm.nih.gov/articles/PMC12641682/) | published, direction unknown | Wang's uniform d ≈ 1.9 across groups and tiny SDs are suspicious; Amaro's effects are negligible. Never assert a direction |
| Release timing (release time, dip-to-release) | Faster release in higher-level juniors; release time lengthens with fatigue | HL "faster (12.5 %) shot release times", t(77) = −3.213, p = 0.002; fatigue +25.34 % (G), +19.73 % (F), +14.95 % (C) | 79 U18; 38 high-level Greek | [Botsi 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC11677033/); [Bourdas et al. 2024, Sports](https://pmc.ncbi.nlm.nih.gov/articles/PMC10974731/) | published | Release time only in tier A |
| Release-parameter variability structure | Lower combined tolerance/noise/covariation cost in more accurate shooters | "C-cost is smaller for the participant whose shot probability of success was high" (no coefficients in abstract) | 8 collegiate males, 50 FTs, 16-camera mocap | [Nakano, Fukashiro & Yoshioka 2018, ISBS](https://commons.nmu.edu/isbs/vol36/iss1/32/) | published (qualitative) | Conference abstract. NOTE: I found no "Nakano 2020 release timing" paper; Nakano's 2020 papers are near-minimum release speed (above) and energy flow vs distance (Sports Biomech 19(3)) — the timing attribution is **UNVERIFIED** |
| The "dip" | Dipping increased accuracy at every distance | ≈ 7–9 % accuracy gain; HS F(1,17) = 27.608, university F(1,17) = 53.081, p < 0.001 | 36 elite males (18 HS, 18 university), 4 distances 3.125–6.75 m | [Penner 2021, Front Psychol](https://pmc.ncbi.nlm.nih.gov/articles/PMC8273237/) | published | Single study, unblinded within-subject, accuracy on a points scale; no retention |
| Backspin | Spin *consistency* matters, mean rate/alignment does not | see Slegers & Love above | — | — | not measurable in v1 | Do not ship a backspin metric |
| Fatigue → mechanics (case study) | Under heavy fatigue shoulder/wrist heights and elbow/upper-arm angles fall | p < 0.05 all variables; "decrease drastically in the last series" at HR 96 % HRpeak, LA 9.7 mmol/L | n = 1 NBA player, 7 × 20 shots at 7.24 m, 3 cameras 50 Hz | [Erculj & Supej 2009, JSCR](https://pubmed.ncbi.nlm.nih.gov/19387370/) | published (n = 1) | Case study; magnitudes not in abstract |
| Fatigue → entry angle and makes | Simulated game reduces entry angle and makes, lengthens release | EA −3.89 % (G), −3.13 % (F), −3.47 % (C); makes −14.42 / −16.76 / −19.44 %; all p ≤ 0.05 | 38 high-level males | [Bourdas et al. 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC10974731/) | published | Wide CIs (e.g. EA −14.82 to 7.04); pre/post, no control |
| Fatigue → 3-pt kinematics (collegiate) | 3-pt % fell, mid-range did not; wrist/elbow angular velocity fell, knee/ankle rose; "reductions in both the shooting angle and incident angle, as well as the extension of shooting time" | p < 0.05 (3-pt %), wrist p < 0.01 | 12 collegiate males, IMU + high-speed camera | [PeerJ 2025](https://peerj.com/articles/19983/) | published | Magnitudes not in abstract |
| Fatigue → no change (elite U18) | No change in release after repeated sprints | velocity 7.77 ± 0.20 vs 7.80 ± 0.13 m/s (p = 0.8); angle 51.1 ± 0.4 vs 51.0 ± 0.2° (p = 0.14); height 2.35 ± 0.24 vs 2.31 ± 0.21 m (p = 0.51) | 10 elite U18 (6 M / 4 F) | [Slawinski et al. 2018, J Hum Kinet](https://pmc.ncbi.nlm.nih.gov/articles/PMC6006537/) | published (null) | Sprint fatigue ≠ shooting-volume fatigue |
| Fatigue → accuracy (meta-analysis) | Accuracy falls with fatigue, more with severity | moderate physical SMD 0.67 [0.24, 1.10]; severe 1.39 [0.76, 2.01]; moderate mental 1.20 [0.23, 2.17]; 3-pt under moderate fatigue n.s. (p = 0.11), severe 1.47 [0.65, 2.29] | 14 studies, 388 participants | [Li et al. 2025, Front Physiol](https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2025.1435810/full) | published | 11 of 14 single-arm; heterogeneous protocols |

## Rules the engine can justify from sources

Schema per `docs/BRIEF.md` §6. All `outcome_separation` rules inherit the global gates (Cohen's d ≥ 0.5,
BH-FDR, within-cell, tier A/B). `threshold` for variance rules is the SD above which the *variance*
finding is surfaced; it is an anchor, not a verdict. Thresholds marked `heuristic` are judgement calls
sitting on a published anchor and should be tuned on accumulated user data.

```yaml
- id: release_speed_variance
  metric: release_speed_mps
  condition_type: variance
  threshold: { sd_gt: 0.13 }          # top of the skilled-shooter range in Slegers 2021 (0.05–0.13 m/s)
  min_n: 30
  required_view_class: side
  required_tier: A
  provenance: published
  provenance_note: "Release-velocity SD vs 3-pt performance r = -0.96, FT r = -0.88 (n = 12). Threshold is the upper end of their skilled range; measurement floor at 30 fps is 0.036 m/s (digest constants)."
  citation: "Slegers N, Lee D, Wong G. The Relationship of Intra-Individual Release Variability with Distance and Shooting Performance in Basketball. J Sports Sci Med. 2021;20(3):508-515. https://pmc.ncbi.nlm.nih.gov/articles/PMC8256521/"

- id: depth_variance
  metric: depth_m
  condition_type: variance
  threshold: { sd_gt: 0.09 }          # heuristic: half of Marty & Lucey GMZ depth window (7"–14" = 0.178 m)
  min_n: 30
  required_view_class: any
  required_tier: A|B
  provenance: heuristic
  provenance_note: "Depth SD is the observable proxy for release-speed SD (Jacobian: +0.1 m/s -> +14.6 cm depth, digest constants). Window anchor from Marty & Lucey 2017 GMZ as restated by Daly-Grafstein & Bornn 2019."
  citation: "Daly-Grafstein D, Bornn L. Rao-Blackwellizing field goal percentage. J Quant Anal Sports. 2019;15(2):85-95. https://www.lukebornn.com/papers/dalygrafstein_jqas_2019.pdf"

- id: depth_outcome_separation
  metric: depth_m
  condition_type: outcome_separation
  threshold: { cohens_d_ge: 0.5 }
  min_n: 30
  required_view_class: any
  required_tier: A|B
  provenance: published
  provenance_note: "NBA 3-pt: make probability highest at 11 in depth; 9 in made 60.1 %, 10 in made 64.5 %; contests bias short. Copy must say 'associated with', direction reported from the player's own data."
  citation: "Daly-Grafstein D, Bornn L. Using in-game shot trajectories to better understand defensive impact in the NBA. J Sports Analytics. 2020;6:235-. https://www.lukebornn.com/papers/dalygrafstein_jsa_2020.pdf"

- id: depth_short_bias
  metric: depth_m
  condition_type: absolute_threshold
  threshold: { mean_lt: 0.2285 }      # rim centre from front rim (geometry); makes peak 0.254–0.279 m (10–11 in)
  min_n: 30
  required_view_class: any
  required_tier: A
  provenance: published
  provenance_note: "Threshold is geometric (rim centre). The claim that makes peak 2 in past centre is empirical NBA data (Daly-Grafstein & Bornn 2019/2020; Marty & Lucey 2017). Noah's 'young players miss short five times more often' is unsourced — do not quote it."
  citation: "Daly-Grafstein & Bornn 2019 (above); Marty R, Lucey S. A data-driven method for understanding and increasing 3-point shooting percentage. MIT Sloan Sports Analytics Conference 2017 (record: https://www.sponet.de/Record/4042342)"

- id: entry_angle_outcome_separation
  metric: entry_angle_deg
  condition_type: outcome_separation
  threshold: { cohens_d_ge: 0.5 }
  min_n: 30
  required_view_class: any
  required_tier: A|B
  provenance: published
  provenance_note: "NBA make probability peaks mid-40s but is flat over a range; U18 higher-level closer to 45 deg (p = 0.006). No universal target — the cell's own split adjudicates."
  citation: "Daly-Grafstein & Bornn 2020 (above); Botsi et al. Comparative Analysis of 2-Point Jump Shot and Free Throw Kinematics in High- and Low-Level U18 Male Basketball Players. JFMK 2024. https://pmc.ncbi.nlm.nih.gov/articles/PMC11677033/"

- id: entry_angle_variance
  metric: entry_angle_deg
  condition_type: variance
  threshold: { sd_gt: 3.0 }           # heuristic: ~2x the release-angle SD of skilled shooters (1.2–1.3 deg) propagated through J (1.46 deg entry per deg release)
  min_n: 30
  required_view_class: any
  required_tier: A|B
  provenance: heuristic
  provenance_note: "Anchor: release-angle SD 1.2 +/- 0.24 deg (3-pt) in skilled shooters (Slegers 2021); angle SD was only weakly predictive, so rank this below speed/depth variance. Noah's 'great shooters vary +/-2 deg' is unsourced."
  citation: "Slegers, Lee & Wong 2021 (above)"

- id: release_angle_vs_min_speed
  metric: release_angle_minus_min_speed_angle_deg   # min-speed angle computed from release height and distance (geometry)
  condition_type: absolute_threshold
  threshold: { mean_lt: 0.0, or_mean_gt: 10.0 }
  min_n: 30
  required_view_class: side
  required_tier: A
  provenance: published
  provenance_note: "Skilled shooters sit 2.8 +/- 3.1 deg (Nakano 2020) / 3.9 deg (Slegers 2022) above the minimum-speed angle; individual optima 4.3 +/- 2.1 deg above. Below 0 = flat-and-hard; above ~10 deg = more than 2 SD above the published mean. Bounds are heuristic around published means."
  citation: "Nakano N, Inaba Y, Fukashiro S, Yoshioka S. Basketball players minimize the effect of motor noise by using near-minimum release speed in free-throw shooting. Hum Mov Sci. 2020;70. https://www.biorxiv.org/content/10.1101/793513v1.full ; Slegers N. Basketball shooting performance is maximized by individual-specific optimal release strategies. Int J Perf Anal Sport. 2022;22(3). https://digitalcommons.georgefox.edu/mece_fac/129/"

- id: lateral_variance
  metric: lateral_m
  condition_type: variance
  threshold: { sd_gt: 0.051 }         # Marty & Lucey GMZ left-right half-width (2 in) as restated in Daly-Grafstein & Bornn 2019
  min_n: 30
  required_view_class: frontal
  required_tier: A
  provenance: published
  provenance_note: "Lateral consistency, not mean offset, predicts accuracy (spin-axis SD r = 0.80; mean misalignment n.s., Slegers & Love 2022). Contests inflate left-right variance 38 % without bias (Daly-Grafstein & Bornn 2020)."
  citation: "Slegers N, Love D. The role of ball backspin alignment and variability in basketball shooting accuracy. J Sports Sci. 2022;40(12). https://pubmed.ncbi.nlm.nih.gov/35611914/"

- id: lateral_outcome_separation
  metric: lateral_m
  condition_type: outcome_separation
  threshold: { cohens_d_ge: 0.5 }
  min_n: 30
  required_view_class: frontal
  required_tier: A
  provenance: published
  provenance_note: "NBA make probability highest at 0 in left-right; falls faster with left-right than with entry angle."
  citation: "Daly-Grafstein & Bornn 2019, 2020 (above)"

- id: entry_angle_session_drift
  metric: entry_angle_deg
  condition_type: drift
  threshold: { slope_abs_change_over_session_gt_deg: 1.5 }   # ~3.5 % of 45 deg, matching Bourdas 2024's -3.1 to -3.9 %
  min_n: 60
  required_view_class: any
  required_tier: A|B
  provenance: published
  provenance_note: "Entry angle fell 3.1–3.9 % after a 12-min simulated game with makes down 14–19 % (n = 38). Null result in elite U18 after sprints (Slawinski 2018) — report drift only when measured."
  citation: "Bourdas DI et al. Basketball Fatigue Impact on Kinematic Parameters and 3-Point Shooting Accuracy. Sports (Basel). 2024;12(3):63. https://pmc.ncbi.nlm.nih.gov/articles/PMC10974731/"

- id: release_height_session_drift
  metric: release_height_m
  condition_type: drift
  threshold: { slope_abs_change_over_session_gt_m: 0.05 }    # heuristic; Erculj & Supej give direction (down) but no magnitude in abstract
  min_n: 60
  required_view_class: side
  required_tier: A
  provenance: published
  provenance_note: "Shoulder-axis and wrist heights fell with fatigue in an NBA player (p < 0.05, 7 x 20 shots); meta-analysis links accuracy loss to 'decrease in shooting height and wrist joint angular velocity'."
  citation: "Erculj F, Supej M. J Strength Cond Res. 2009;23(3):1029-1036. https://pubmed.ncbi.nlm.nih.gov/19387370/ ; Li et al. Front Physiol 2025. https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2025.1435810/full"

- id: release_time_session_drift
  metric: release_time_s
  condition_type: drift
  threshold: { relative_change_over_session_gt: 0.15 }       # Bourdas 2024: +14.95 to +25.34 %
  min_n: 60
  required_view_class: side
  required_tier: A
  provenance: published
  provenance_note: "Release time lengthened 15–25 % post-fatigue; faster release distinguished higher-level U18 (12.5 %, p = 0.002)."
  citation: "Bourdas et al. 2024 (above); Botsi et al. 2024 (above)"

- id: elbow_flare_outcome_separation
  metric: elbow_flare_deg
  condition_type: outcome_separation
  threshold: { cohens_d_ge: 0.5 }
  min_n: 30
  required_view_class: frontal
  required_tier: A|B
  provenance: published
  provenance_note: "Forearm angle from vertical 7.9 +/- 7.2 vs 19.8 +/- 17.6 deg (proficient vs non), and the only variable separating made/missed within proficient (n = 17). Between-group; hypothesis only."
  citation: "Cabarkapa D, Fry AC, et al. Key Kinematic Components for Optimal Basketball Free Throw Shooting Performance. Cent Eur J Sport Sci Med. 2021;36(4):5-15. https://wnus.usz.edu.pl/cejssm/file/article/download/19306/78716.pdf"

- id: elbow_angle_release_outcome_separation
  metric: elbow_angle_release_deg
  condition_type: outcome_separation
  threshold: { cohens_d_ge: 0.5 }
  min_n: 30
  required_view_class: side
  required_tier: A|B
  provenance: published
  provenance_note: "3-pt makes: elbow 47.0 vs 53.0 deg (p = 0.013) in proficient females (Cabarkapa 2023); elbow extension 158.1 vs 152.3 deg, d = 1.92 (Wang 2026, quality caveat). Direction not asserted."
  citation: "Cabarkapa et al. JFMK 2023. https://pmc.ncbi.nlm.nih.gov/articles/PMC10531893/ ; Wang et al. Front Sports Act Living 2026. https://pmc.ncbi.nlm.nih.gov/articles/PMC13291941/"

- id: knee_flexion_outcome_separation
  metric: knee_flexion_depth_deg
  condition_type: outcome_separation
  threshold: { cohens_d_ge: 0.5 }
  min_n: 30
  required_view_class: side
  required_tier: A|B
  provenance: published
  provenance_note: "Proficient 3-pt shooters loaded deeper in preparation (knee 94.3 vs 113.2 deg) with no release-phase differences (n = 24); proficient FT shooters had lower knee angular velocity (212.9 vs 269.4 deg/s). Between-group."
  citation: "Cabarkapa D, Cabarkapa DV, Fry AC. Biomechanical determinants of proficient 3-point shooters. Front Sports Act Living 2026. https://pmc.ncbi.nlm.nih.gov/articles/PMC12935449/ ; Cabarkapa et al. 2023. https://pmc.ncbi.nlm.nih.gov/articles/PMC10436204/"

- id: release_height_outcome_separation
  metric: release_height_m
  condition_type: outcome_separation
  threshold: { cohens_d_ge: 0.5 }
  min_n: 30
  required_view_class: side
  required_tier: A
  provenance: published
  provenance_note: "Direction conflicts across studies (higher = made in Wang 2026; higher = missed within proficient in Cabarkapa 2023; negligible in Amaro 2025). Ship only as the player's own separation, never with a direction in copy."
  citation: "Amaro et al. JFMK 2025. https://pmc.ncbi.nlm.nih.gov/articles/PMC12641682/ ; Cabarkapa 2023 and Wang 2026 (above)"

- id: apex_height_outcome_separation
  metric: apex_height_m
  condition_type: outcome_separation
  threshold: { cohens_d_ge: 0.5 }
  min_n: 30
  required_view_class: any
  required_tier: A|B
  provenance: published
  provenance_note: "Made 3-pt jump shots had 'higher maximal trajectory height' (abstract only; numbers UNVERIFIED)."
  citation: "Cabarkapa et al. Biomechanics 2022;2(3):352-360. https://www.mdpi.com/2673-7078/2/3/28"

- id: dip_outcome_separation
  metric: dip_depth_m                 # tier-2 pose metric, only if reliably detected
  condition_type: outcome_separation
  threshold: { cohens_d_ge: 0.5 }
  min_n: 30
  required_view_class: side
  required_tier: B
  provenance: published
  provenance_note: "Dip raised accuracy ~7–9 % at all distances in 36 elite HS/university males (single unblinded study)."
  citation: "Penner LSJ. Mechanics of the Jump Shot: The 'Dip' Increases the Accuracy of Elite Basketball Shooters. Front Psychol 2021. https://pmc.ncbi.nlm.nih.gov/articles/PMC8273237/"

- id: release_speed_sd_trend
  metric: release_speed_sd_mps        # per-session SD, compared across sessions
  condition_type: trend
  threshold: { sessions_min: 4, relative_change_gt: 0.25 }
  min_n: 30                           # per session
  required_view_class: side
  required_tier: A
  provenance: heuristic
  provenance_note: "No published longitudinal anchor for SD trend; the variable itself is the best-supported correlate (Slegers 2021). Guard with regression-to-the-mean rules (Ch 16)."
  citation: "Slegers, Lee & Wong 2021 (above)"
```

Rules deliberately **not** proposed: backspin (unmeasurable), wrist/finger (BRIEF §5), quiet eye (not
visible), any absolute entry-angle band (see folklore), any rule that asserts a direction for release
height.

## Claims that are folklore / not supported — do not ship

| Claim | Status | Why |
|---|---|---|
| "45° is the optimal entry angle for every shooter" | Not supported as a universal | Optimal release angle is individual (4.3 ± 2.1° above min-velocity, varying with each shooter's release distribution — [Slegers 2022](https://digitalcommons.georgefox.edu/mece_fac/129/)); NBA make probability is flat over a range of entry angles ([Daly-Grafstein & Bornn 2020](https://www.lukebornn.com/papers/dalygrafstein_jsa_2020.pdf)); the same NBA player shoots "about 38 degrees" mid-range, "about 53 degrees" FT, "about 45 degrees" 3-pt ([Nylon Calculus 2018](https://fansided.com/2018/04/24/nylon-calculus-noah-fix-every-jumpshot/)); textbook correction A-C5 puts the optimum at 44.5–54° depending on error mix. Use "mid-40s is where NBA makes cluster" as context, never as a target. |
| "45° shooters make 68 % vs 57 % (53°) vs 56 % (35 °) of free throws; very skilled 96/89/80 %" | Marketing numbers, no methodology | Source is a 2010 trade-magazine article quoting Noah; no n, no design, no error bars; the only described experiment is a shooting *machine* taking 250 FTs at each of 35/40/45/50/55° ([Noah, "Building the Perfect Arc" PDF](https://www.noahbasketball.com/hs-fs/file-649020446-pdf/PDFs/building-the-perfect-arc.pdf?t=1396974603000)). |
| "Great shooters vary only ± 2° in arc"; "only 1 percent of athletes can control their arc within 2 degrees" | Unsourced | Noah claims ([make-shots](https://www.noahbasketball.com/make-shots); PDF above). Published skilled-shooter release-angle SD is 1.2–1.3° but was a weak predictor ([Slegers 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC8256521/)). |
| "Young players miss short five times more often than long" | Unsourced | [Noah blog](https://www.noahbasketball.com/blog/the-art-and-science-of-45/11) gives no data. The published short-bias evidence is NBA contested shots, not youth ([Daly-Grafstein & Bornn 2020](https://www.lukebornn.com/papers/dalygrafstein_jsa_2020.pdf)). |
| "Arc above 47–48° loses depth control"; "1° of arc = up to 2 inches of depth" | Unsourced as stated | [Noah blog](https://www.noahbasketball.com/blog/is-a-higher-arc-really-better). The physics is directionally right (sensitivity to speed error rises with angle; ∂depth/∂θ flips sign at 50.72°, digest constants) but the specific numbers are not from a study. Use the geometry, cite the geometry. |
| "Higher release point is always better" | Contradicted | Missed FTs had *higher* release than makes within proficient shooters (p = 0.035) ([Cabarkapa 2023](https://pmc.ncbi.nlm.nih.gov/articles/PMC10436204/)); negligible ρ = 0.116 in national-level players ([Amaro 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12641682/)). |
| "Swish everything / aim for the centre" | Not supported | Makes peak 2″ past centre; 9″ (centre) made 60.1 % vs 10″ 64.5 % ([Daly-Grafstein & Bornn 2020](https://www.lukebornn.com/papers/dalygrafstein_jsa_2020.pdf)). |
| "Backspin rate X rpm is ideal" | No evidence found | Only spin-axis *consistency* predicts accuracy; mean alignment does not ([Slegers & Love 2022](https://pubmed.ncbi.nlm.nih.gov/35611914/)). |
| "Fatigue always flattens the arc / lowers release" | Not universal | No release change in elite U18 after repeated sprints ([Slawinski 2018](https://pmc.ncbi.nlm.nih.gov/articles/PMC6006537/)); moderate fatigue had no significant 3-pt effect in meta-analysis ([Li 2025](https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2025.1435810/full)). Measure drift; never assume it. |
| "Keep the elbow in / under the ball" as a universal fix | Between-group association only | Forearm angle differed between proficient and non-proficient groups ([Cabarkapa & Fry 2021](https://wnus.usz.edu.pl/cejssm/file/article/download/19306/78716.pdf)); excellent vs good pros showed *no* kinematic differences ([Cabarkapa 2022](https://pmc.ncbi.nlm.nih.gov/articles/PMC9590067/)). Hypothesis for the player's own data, not an instruction. |
| "Noah/RSPCT feedback improves shooting % by N %" / "Reed Sheppard went 32 % → 52 %" / "team went 58 % → 74 %" | Anecdotes | [PRWeb 2025](https://www.prweb.com/releases/new-study-analyzing-over-500-million-shots-reveals-what-nba-teams-have-been-keeping-a-secret-until-now-302601522.html), Noah PDF above, [CTech on RSPCT](https://www.calcalistech.com/ctech/articles/0,7340,L-3721402,00.html) ("20 % improvement in cluster accuracy in just 5 minutes"). No control groups, no peer review found. |
| "Less than 10 % of HS players shoot the correct arc and depth" | Unsourced | [PRWeb 2025](https://www.prweb.com/releases/new-study-analyzing-over-500-million-shots-reveals-what-nba-teams-have-been-keeping-a-secret-until-now-302601522.html); "correct" presupposes the 45/11 target. |
| "Random practice beats blocked" as a blanket rule for shooting | Nuanced | Blocked wins acquisition, loses retention/transfer in novices ([Shamshiri 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12481044/)); variable practice merely *equalled* constant practice on FT retention ([Shoenfelt 2002](https://journals.sagepub.com/doi/10.2466/pms.2002.94.3c.1113)). Fine for a drill's `practice_structure`, not for a finding. |
| External focus / reduced feedback frequency are established | Contested | Already in digest Ch 17 (McKay 2022/2024). Not repeated. |

Items I looked for and could not find: a "Kalsi" shooting-biomechanics paper (no hit — **UNVERIFIED**
that it exists); a "Chang" shooting-mechanics paper (the only Chang cited in this literature is a
2014 Sloan shot-quality paper, not mechanics — **UNVERIFIED**); a Nakano 2020 release-timing paper
(see table); numeric tables of Cabarkapa 2022 made/missed jump shots (publisher 403); Podmenik et al.
2017 Kinesiology 49(1):92–100 (located, not read — **UNVERIFIED** content); Okazaki, Rodacki & Satern
2015 Sports Biomech 14(2):190–205 (abstract only; confirms it is a systematic review of trajectory
variables and jump-shot phases — no numbers extracted).

## Intervention / feedback evidence, with design notes

**Trajectory / arc / depth feedback (the thing ArcLab does).**
- *Noah Basketball.* No peer-reviewed controlled trial found. The 2010 article describes: measuring
  "well over 10,000 shooters", a NASA-scientist model, a programmable shooting machine (250 FTs at
  each of 35/40/45/50/55°; "45 degrees" made most), and before/after anecdotes (16/25 at 36° arc →
  22/25 at 48°; 6/10 at 55°/7″ → 10/10 at 47°/12″ "two minutes later"; a team 58 % → 74 % FT
  season-over-season) ([PDF](https://www.noahbasketball.com/hs-fs/file-649020446-pdf/PDFs/building-the-perfect-arc.pdf?t=1396974603000)).
  The company cites "two scientifically controlled motor skills studies" it does not name or link
  ([blog](https://www.noahbasketball.com/blog/is-a-higher-arc-really-better)). Design quality:
  uncontrolled, unblinded, immediate-effect, no retention, selection of examples. Marty & Lucey 2017
  is *observational* (1.1 M shots; ML predicts 3P % within 1.5 % from four factors) — it validates the
  metrics, not the feedback ([PRNewswire](https://www.prnewswire.com/news-releases/noah-basketball-wins-startup-competition-at-mit-sloan-sports-analytics-conference-300419988.html)).
- *RSPCT.* Marketing only ([CTech](https://www.calcalistech.com/ctech/articles/0,7340,L-3721402,00.html)).
- *AR optimal-trajectory feedback (closest peer-reviewed analogue).* 20 novices randomised 10/10;
  three blocks of 20 FTs. AR group 22.0 ± 9.8 % → 29.5 ± 7.3 % (with overlay) → 41.0 ± 15.6 % (overlay
  removed), pre-post p = 0.0039; control 33.0 → 31.0 → 34.5 % (p = 0.70); **no significant
  between-group difference** ([Ueyama & Harada 2024, Sci Rep](https://pmc.ncbi.nlm.nih.gov/articles/PMC10776772/)).
  Design: single session, no retention, baseline imbalance (22 % vs 33 %), novices — a
  regression-to-the-mean magnet. Supports "trajectory feedback is not harmful and may help novices";
  does not support a percentage claim.
- *Self-controlled video feedback.* 28 novice women; self-controlled group had better *form* on
  transfer (F(1,26) = 4.67, p = 0.04, η² = 0.153) and requested video on 27 % of trials; **no accuracy
  difference** at any phase ([Aiken, Fairbrother & Post 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3438820/)).
  Useful design cue: letting the player choose when to look at a replay is at least not worse.
- *AI video feedback, 8 weeks, n = 24* (computer.org conference paper surfaced by search) —
  **UNVERIFIED**, not fetched; conference venue, treat as low quality.

**Quiet-eye training (large effects, weak designs, invisible to ArcLab).**
- Harle & Vickers 2001: one university team trained over two seasons vs two untrained teams;
  competition FT % reported as rising from 54 % to 76 %, "improved … by 22.62 % to 76.66 %"
  ([journal page](https://journals.humankinetics.com/view/journals/tsp/15/3/article-p289.xml);
  numbers taken from the abstract as indexed by search — I could not open the abstract itself, so
  treat the exact figures as **partially verified**). Design: non-randomised, team-level n = 3,
  season-to-season confounds.
- Vine & Wilson 2011: 16 novices randomised; 520 FTs over 8 days; QE group "performed significantly
  better in the pressure test" ([PubMed](https://pubmed.ncbi.nlm.nih.gov/21276584/)). No percentages
  in abstract.
- Lebeau et al. 2016 meta-analysis: intervention studies (9 articles) QE d = 1.53, performance
  d = 0.84; expert–novice d = 1.04; successful vs unsuccessful d = 0.58 ([JSEP](https://journals.humankinetics.com/view/journals/jsep/38/5/article-p441.xml)).
  Caveat: small studies from a few labs; "QE" critics exist. Implication: a QE cue can live in the
  drill layer (`external_cue` passes the validator: "hold your eyes on the back of the rim"), but
  ArcLab cannot measure it and should not claim it.

**Practice structure.**
- Shoenfelt et al. 2002: 94 participants matched then randomised to constant vs three variable
  conditions, 4 days/week × 3 weeks; all improved similarly; most-variable group equal on delayed
  retention despite lower practice performance ([PMS](https://journals.sagepub.com/doi/10.2466/pms.2002.94.3c.1113)).
  Design: decent; population unclear from abstract.
- Shamshiri et al. 2025: 84 novice females, 7 groups of 12, 3 days: blocked best in acquisition
  (1.79 vs 1.11–1.52), worst in retention (1.28 vs 1.69–1.73, ηp² = 0.24) and transfer (0.54 vs
  1.27–1.38, F = 15.50, p < 0.001) ([EJSS](https://pmc.ncbi.nlm.nih.gov/articles/PMC12481044/)).
  Design: randomised, but 3 days and novices — transfer to a 300-rep/session HS player is unknown.
- Penner 2021 (dip): 36 elite males, within-subject with/without dip at four distances; 7–9 % gain,
  F(1,17) = 27.6 (HS) and 53.1 (university) ([Front Psychol](https://pmc.ncbi.nlm.nih.gov/articles/PMC8273237/)).
  Design: unblinded, single session, instructed-technique comparison — an acute effect, not learning.

**What this means for the engine.** Nothing here licenses a "do X and your percentage rises N %"
claim. The defensible product statements are (a) within-player associations (depth/entry/lateral
separation, speed/depth variance), (b) drift measured on the player's own session, and (c) drills
labelled `coach_recommended` until the Ch 16 efficacy table earns `in_house_n30`.

## Reference ranges by distance and level (what is published vs folklore)

| Quantity | Published values | Folklore / marketing |
|---|---|---|
| Entry angle, NBA 3-pt | mean ≈ 45°, makes cluster mid-40s, probability flat over a range ([Daly-Grafstein & Bornn 2019/2020](https://www.lukebornn.com/papers/dalygrafstein_jqas_2019.pdf)) | "45–47 is the perfect arc" ([Noah](https://www.noahbasketball.com/blog/noah-basketball-shot-mechanics-shooting-arc-secrets)); "91 % of NBA players 43–47°" (in digest constants; I could not find a primary source — **UNVERIFIED**) |
| Depth, NBA 3-pt | mean 11″ from front rim (2″ past centre); makes peak 10–11″; GMZ 7–14″ made >90 % (Noah) / 85.2 % (SportVU estimate) | "11 inches" as a universal target for youth |
| Left-right | mean 0″; GMZ ± 2″ | — |
| Release angle vs distance | 52–55° (2.74–4.57 m), 48–50° (6.40 m) in 15 males ([Miller & Bartlett 1996](https://pubmed.ncbi.nlm.nih.gov/8809716/)); pros 60.8 ± 6.3° FT, 58.9 ± 7.4° 2-pt, 56.9 ± 8.5° 3-pt ([Cabarkapa 2022](https://pmc.ncbi.nlm.nih.gov/articles/PMC9590067/)); elite U18 3-pt 51.1 ± 0.4° ([Slawinski 2018](https://pmc.ncbi.nlm.nih.gov/articles/PMC6006537/)) | any single "correct" release angle |
| Release-angle deviation above minimum-speed angle | 2.8 ± 3.1° (collegiate FT), 3.9° mean / 4.3 ± 2.1° optimal (3-pt) | — |
| Release-speed SD, skilled | 0.05–0.13 m/s (FT and 3-pt alike) | — |
| Release-angle SD, skilled | 1.2–1.3° | "± 2°" |
| Release speed, 3-pt elite U18 | 7.77 ± 0.20 m/s | — |
| Release height | 2.35 ± 0.24 m (elite U18 3-pt); 2.28 ± 0.06 m athletes / 2.15 ± 0.08 m novices FT (Wang 2026, caveat) | "release as high as possible" |
| Within-session fatigue shift | entry angle −3.1 to −3.9 %, release time +15 to +25 %, makes −14 to −19 % after 12-min BEST (high-level adults); zero shift after sprints (elite U18) | "everyone's arc drops when tired" |

Distance-specific ranges for HS/college players from *practice* (not NBA game) data do not exist in
the sources found; ArcLab's own per-cell baselines will be the first such reference for each user,
which is the product thesis.
