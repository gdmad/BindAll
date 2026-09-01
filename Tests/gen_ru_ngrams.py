#!/usr/bin/env python3
"""Builds the Russian n-gram seed files for BindAll's autocomplete from a sentence corpus.

Usage: gen_ru_ngrams.py <sentences.txt> <outdir> [--top-bigrams N] [--top-trigrams N]

Input: one sentence per line (UTF-8), any sentence-level corpus. The Leipzig Corpora Collection
Russian news corpus (https://wortschatz.uni-leipzig.de, rus_news_2023, CC BY 4.0) is the source
used to generate the shipped files.

Output (tab-separated, counts = total occurrences across the corpus, sorted by count descending):
  <outdir>/ru_bigrams_ctx.txt   prev \t next \t count            (top N bigrams)
  <outdir>/ru_trigrams.txt     prev2 \t prev1 \t next \t count  (top N trigrams)

Tokens: contiguous letter runs (Cyrillic + Latin), lowercased, e/yo kept as typed ("е" and "ё"
are distinct keys, matching the learning store). Punctuation and numbers split tokens.
"""
import collections
import re
import sys

TOKEN_RE = re.compile(r"[^\W\d_]+", re.UNICODE)  # letter runs (no digits/underscore)


def tokenize(line: str):
    return [t.lower() for t in TOKEN_RE.findall(line)]


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--top")]
    if len(args) < 2:
        print(__doc__)
        sys.exit(2)
    top_bigrams = 50_000
    top_trigrams = 150_000
    for flag in sys.argv[1:]:
        if flag.startswith("--top-bigrams="):
            top_bigrams = int(flag.split("=", 1)[1])
        elif flag.startswith("--top-trigrams="):
            top_trigrams = int(flag.split("=", 1)[1])

    src, outdir = args
    bigrams = collections.Counter()
    trigrams = collections.Counter()
    n_sentences = 0
    n_words = 0
    with open(src, encoding="utf-8") as f:
        for line in f:
            ws = tokenize(line)
            if len(ws) < 2:
                continue
            n_sentences += 1
            n_words += len(ws)
            for i in range(1, len(ws)):
                bigrams[(ws[i - 1], ws[i])] += 1
                if i >= 2:
                    trigrams[(ws[i - 2], ws[i - 1], ws[i])] += 1

    import os
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "ru_bigrams_ctx.txt"), "w", encoding="utf-8") as f:
        for (p, n), c in bigrams.most_common(top_bigrams):
            f.write(f"{p}\t{n}\t{c}\n")
    with open(os.path.join(outdir, "ru_trigrams.txt"), "w", encoding="utf-8") as f:
        for (p2, p1, n), c in trigrams.most_common(top_trigrams):
            f.write(f"{p2}\t{p1}\t{n}\t{c}\n")
    print(f"sentences={n_sentences} words={n_words} "
          f"unique_bigrams={len(bigrams)} unique_trigrams={len(trigrams)} "
          f"-> {outdir}")


if __name__ == "__main__":
    main()
