# Elasticsearch and XenForo Enhanced Search

The `elasticsearch` service in this stack is the *backend*. **XenForo Enhanced Search (XFES) is a separately licensed XenForo add-on** that you install into the board yourself — it is not included here, and the stack works without it (XenForo falls back to MySQL search).

---

## Wiring XFES to this stack

Install the add-on, then in the ACP go to **Setup → Enhanced Search** and enter:

| Field | Value |
|---|---|
| Host | `elasticsearch` |
| Port | `9200` |
| Index name | `xf` |
| HTTPS | off |
| Username / password | blank |

`elasticsearch` is the compose service name; Docker's embedded DNS resolves it inside the network. **Do not use `localhost` or `127.0.0.1`** — inside the web container that means the web container itself.

Then verify from the host:

```bash
./xf.sh doctor          # includes cluster health and the xf index document count
./xf.sh es              # _cat/indices?v
./xf.sh es "xf/_count"
```

Configuration lives in XenForo **options**, i.e. in the database — not in `config.php`. So it does not survive `xf reset`, and a `_data` import can't carry it between installs. Re-running the wizard takes 30 seconds.

---

## Version compatibility

XFES requires **Elasticsearch 7.2.0 minimum**. Below that it refuses to connect.

**OpenSearch is supported** and handled specially: when the server reports `version.distribution == 'opensearch'`, XFES pins its internal version to `7.10.2` regardless of the real number — because OpenSearch forked from ES 7.10.2 and its own 1.x/2.x/3.x numbering would fail the version comparison. Feature checks therefore behave as ES 7.10, never better.

This stack pins **8.15.0**. To use OpenSearch instead:

```yaml
elasticsearch:
  image: opensearchproject/opensearch:2.15.0
  environment:
    - discovery.type=single-node
    - DISABLE_SECURITY_PLUGIN=true          # same unpublished-port rule applies
    - OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx1g
```

---

## "Yellow" is correct here

```
status: yellow
```

A single-node cluster cannot allocate replica shards — there is no second node to put them on — so `xf` sits at yellow permanently. This is expected, not a fault. Only **red** indicates a real problem.

The healthcheck in `docker-compose.yml` accepts green or yellow for exactly this reason.

---

## Reindexing

```bash
./xf.sh reindex                    # everything
./xf.sh reindex --type=post        # one content type
```

The command is `xf-rebuild:search`. XenForo's `AbstractRebuildCommand` builds every rebuild command as `xf-rebuild:<name>`; there is no `xf:rebuild-search`. The ACP equivalent is under Setup → Enhanced Search.

Full reindexes are slow and hammer both MySQL and Elasticsearch. On a dev board with seeded content it's seconds; on a copy of a production database it is not.

**Changing any analyzer setting deletes and recreates the index.** XFES's optimizer calls `deleteIndex()` as part of applying analyzer changes, so a full reindex must follow — otherwise the board is searching an empty index and every query returns nothing.

---

## "Old content doesn't come back in search"

A recurring complaint, and it has **three distinct causes** that need different fixes. These findings come from a measured experiment on a local install of this stack (261 seeded documents, backdated to 2019, 2022 and 2026).

### 1. Age never filters. It only re-ranks.

XFES wraps the query in a `function_score` carrying an exponential decay on `date`. There is **no `min_score` anywhere in XFES**, so a decayed document is never dropped — the same rare term at 2019, 2022 and 2026 returned all three.

The ranking penalty is steep, though. Three documents with *identical* BM25 relevance (3.4958 each), scored after decay:

| Document age | halfLife 365 (default) | halfLife 1095 | halfLife 3650 |
|---|---|---|---|
| 2026 | 100% | 100% | 100% |
| 2022 | **6.2%** | 39.7% | 75.8% |
| 2019 | **0.8%** | 19.8% | 61.5% |

If old content is present but buried, raise the half-life in the XFES recency-relevance option.

### 2. What actually *removes* old content is the result cap

XenForo's `maximumSearchResults` becomes Elasticsearch's `size` (×4 if the query has constraints, ×4 again for group-by, hard cap 10000). With 261 matching documents, the 2019 thread was **not returned at all** at the default 200 — raising the cap to 1000 returned it, at rank 261.

On a busy board this reads exactly like "old content was never indexed."

The fix is an ordinary ACP setting, not a code change: **Setup → Options → Search options → "Maximum number of search/find new results"**. Note its own explain text: the cap applies **before** permission filtering, so a restricted member sees fewer results than the configured number.

Because of the ×4/×4 scaling, **625 is the practical ceiling**:

| Setting | Worst-case ES `size` | Clamped? |
|---|---|---|
| 200 (default) | 3,200 | no |
| 500 | 8,000 | no |
| 625 | 10,000 | at the ceiling |
| 1000 | 10,000 | yes, silently |

Above 625 the heaviest queries hit the clamp silently while lighter ones still pay the cost.

### 3. A literal *zero* results is usually the analyzer, not age

XFES ships with `stemming: none`, `stop: none`, `ascii_folding: false`.

Measured: content containing `flangebolt`, searched as `flangebolts` → **0 hits**. Enable `stemming: language`/`porter2`, recreate the index, reindex → **1 hit**.

Any singular/plural or word-form difference misses completely, at any age. **Check this first** when the complaint is "returns nothing" rather than "returns only recent things".

### Order of investigation

```bash
# Is the term in the index at all, regardless of scoring?
./xf.sh es 'xf/_count' # then, for a specific term:
docker compose exec xenforo curl -s "http://elasticsearch:9200/xf/_count" \
  -H 'Content-Type: application/json' -d '{"query":{"match":{"message":"<term>"}}}'

# Did indexing silently fail for some content?
./xf.sh db -e "SELECT COUNT(*) FROM xf_es_index_failed;"

# Is the index read-only? ES flips to this at the 95% disk flood stage and every
# subsequent index request fails. (This stack disables the threshold, but a
# production cluster won't have.)
./xf.sh es "xf/_settings?flat_settings"
```

If `_count` finds it but a user search doesn't → ranking + cap (2), or permissions (a member who can't view the node gets zero). If `_count` finds nothing → analyzer (3) or a genuine indexing gap.

---

## Third-party search add-ons

Two commonly encountered add-ons extend XFES. Both change where you should look.

**SV Elasticsearch Essentials** owns the **ngram min/max size** fields that appear on the Enhanced Search ACP page. Core XFES has no ngram setting at all — if you see those fields, Essentials is installed. Three things follow:

- min 1 / max 25 are its stock defaults, not a misconfiguration. Values outside 1–32 are silently reverted.
- It is **`edge_ngram` — prefixes only**. `fibergaskets` indexes as `f`, `fi`, `fib` … It can never match `gaskets` *inside* `fibergaskets`. Edge ngrams solve as-you-type matching, not compound-word mismatches.
- It applies to a title field only, never to `message` — and that field isn't consulted by an ordinary keyword search. **So the ngram settings are neither the cause of, nor the fix for, a body-text term returning zero.**

Its two options that *do* hard-cut by date — `svESE_AutocompleteDateLimit` and `svESE_AutocompleteLastUpdatedLimit` (both default 0/off) — are the only date-based *exclusions* in this stack. Everything else merely re-ranks. Check them first if the complaint is specifically about the search-as-you-type dropdown.

**SV Search Improvements** maintains a separate specialized index (users, tags) and does not govern normal content search.

---

## Running without Elasticsearch

If you're working on an add-on unrelated to search, drop the memory and battery cost. In `stack/docker-compose.yml`, comment out the `elasticsearch` service **and** the `depends_on` entry that references it:

```yaml
    depends_on:
      mariadb:
        condition: service_healthy
      # elasticsearch:
      #   condition: service_healthy
```

XenForo falls back to MySQL search automatically when XFES cannot reach a cluster. Just don't then report search bugs from that configuration.

---

## Security, once more

The Elasticsearch service here runs with `xpack.security.enabled=false` and **has no published port**. Anyone who can reach port 9200 has unauthenticated administrative control of the cluster and can delete every index.

Query it through the web container (`./xf.sh es`, `docker compose exec xenforo curl ...`), never by publishing the port. If you want Kibana, attach it to the compose network as another service and publish *Kibana's* port, loopback-bound. Full reasoning in [SECURITY.md](SECURITY.md).
