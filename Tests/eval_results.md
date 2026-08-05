# Autocomplete ranking experiment — results

Evaluator: `Tests/eval_autocomplete.sh <variant> <cold|warm> [limit] [bigramSeed] [trigramSeed]` —
RU-only corpus (`Tests/ru_eval_corpus.txt`, 105 sentences: 80 hand-written + 25 Leipzig news),
limit=5, language `ru`, words with >= 2 previous words as context, prefixes 3/4/5.

Metric definitions: hit@1 / hit@3 = fraction of trials where the correct completion is the 1st /
within the top 3 suggestions; MRR = mean reciprocal rank (0 when absent); absent = correct word not
in the returned top-5.

Corpus note: extended from 80 to 105 sentences after variant A (news block added); all numbers below
are on the final 105-sentence corpus. Cold = empty learning store; warm = corpus pre-recorded twice.

## Baseline (current behavior: learned -> NSSpellChecker completions -> guesses, no context)

| setup | prefix | trials | hit@1 | hit@3 | MRR | absent |
|---|---|---|---|---|---|---|
| cold | 3 | 299 | 24.4% | 37.1% | 0.319 | 162 |
| cold | 4 | 258 | 29.8% | 45.7% | 0.387 | 114 |
| cold | 5 | 187 | 29.9% | 48.1% | 0.404 | 73 |
| cold | all | 744 | 27.7% | 42.9% | 0.364 | 349 |
| warm | 3 | 299 | 72.2% | 94.3% | 0.832 | 6 |
| warm | 4 | 258 | 86.8% | 98.8% | 0.927 | 1 |
| warm | 5 | 187 | 87.7% | 98.9% | 0.932 | 1 |
| warm | all | 744 | 81.2% | 97.0% | 0.890 | 8 |

## Variant A (context n-gram re-ranking, current seed)

Mode: `context`, seed = bundled `ru_bigrams.txt` (4886 Google Books bigrams), no trigram seed.
Pool = learned + NSSpellChecker completions (up to 30), re-ranked by `store.contextScore`
(learned trigram > learned bigram > seed bigram > personal frequency, normalized per context).
Spelling guesses are not used.

| setup | prefix | trials | hit@1 | hit@3 | MRR | absent |
|---|---|---|---|---|---|---|
| cold | 3 | 299 | 32.4% | 44.8% | 0.395 | 144 |
| cold | 4 | 258 | 38.8% | 51.6% | 0.454 | 110 |
| cold | 5 | 187 | 36.4% | 49.2% | 0.439 | 76 |
| cold | all | 744 | 35.6% | 48.3% | 0.426 | 330 |
| warm | 3 | 299 | 100.0% | 100.0% | 1.000 | 0 |
| warm | 4 | 258 | 100.0% | 100.0% | 1.000 | 0 |
| warm | 5 | 187 | 100.0% | 100.0% | 1.000 | 0 |
| warm | all | 744 | 100.0% | 100.0% | 1.000 | 0 |

Cold vs baseline: hit@1 27.7% -> 35.6% (+7.9pp), MRR 0.364 -> 0.426.

## Variant B (context n-gram re-ranking, rich seed data)

Mode: `context`, seed = `ru_bigrams_v2.txt` (50k Leipzig bigrams) + `ru_trigrams.txt` (150k Leipzig
trigrams; Leipzig rus_news_2023, CC BY 4.0). Source note: raw Google Books n-gram shards are
400-750 MB each — impractical to ship a generation pipeline for; Leipzig gives the same kind of
top-N RU n-gram data at a practical size.

| setup | prefix | trials | hit@1 | hit@3 | MRR | absent |
|---|---|---|---|---|---|---|
| cold | 3 | 299 | 40.1% | 52.2% | 0.463 | 129 |
| cold | 4 | 258 | 45.7% | 58.1% | 0.518 | 98 |
| cold | 5 | 187 | 45.5% | 57.8% | 0.520 | 66 |
| cold | all | 744 | 43.4% | 55.6% | 0.496 | 293 |
| warm | 3 | 299 | 100.0% | 100.0% | 1.000 | 0 |
| warm | 4 | 258 | 100.0% | 100.0% | 1.000 | 0 |
| warm | 5 | 187 | 100.0% | 100.0% | 1.000 | 0 |
| warm | all | 744 | 100.0% | 100.0% | 1.000 | 0 |

Cold vs A cold: hit@1 35.6% -> 43.4% (+7.8pp), MRR 0.426 -> 0.496, absent 330 -> 293.
The data-only contribution is isolated by A-vs-B in cold mode (same mechanism, different seeds);
in warm mode the learned model dominates both equally (100%).

## Variant C (semantic re-ranking, NLContextualEmbedding)

Mode: `semantic` — pool = learned + NSSpellChecker completions (up to 30), re-ranked by cosine
similarity between the context embedding and each candidate word, using the on-device Cyrillic
`NLContextualEmbedding` (512-dim, length-weighted mean pooling). Two scorers measured:
pure similarity, and the plan's spec: similarity + learned-word frequency prior.

Pure semantic (cold): hit@1 15.7% / MRR 0.235 — far below baseline (27.7% / 0.364).
Pure semantic (warm): hit@1 21.6% / MRR 0.311 — far below baseline warm (81.2% / 0.890).
With frequency-prior blend (cold): 15.7% / 0.235 (frequency prior is 0 in cold, no change).
With frequency-prior blend (warm): hit@1 44.2% / MRR 0.528 — better than pure but still below
baseline warm.

Verdict: isolated-word BERT embeddings do not carry the syntactic/agreement signal Russian
completion needs ("мы пойдем" -> пойдем scores 0.92, but пойдешь scores 0.81 — the wrong forms are
too close, and the semantic signal actively displaces correct learned words). Variant C is not
viable as a ranking signal; it is dropped from the winner selection.

## Winner selection (phase 5)

| variant | cold hit@1 | cold MRR | warm hit@1 | warm MRR |
|---|---|---|---|---|
| baseline | 27.7% | 0.364 | 81.2% | 0.890 |
| A (context, old seed) | 35.6% | 0.426 | 100.0% | 1.000 |
| B (context, rich seed) | 43.4% | 0.496 | 100.0% | 1.000 |
| C pure | 15.7% | 0.235 | 21.6% | 0.311 |
| C + frequency blend | 15.7% | 0.235 | 44.2% | 0.528 |

Winner: **B** — context n-gram re-ranking with the rich seed data (biggest cold-start gain, warm
parity). The engine's `semantic` mode and `SemanticRanker` are kept behind the debug switch only
(no default path uses them).

