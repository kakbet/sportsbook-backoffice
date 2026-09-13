#!/usr/bin/env bash
# Decide which image tags a build-push run is allowed to publish.
#
# `:latest`, `:<version>` and the `v<version>` GitHub release are PRODUCTION
# names: helm values resolve them and `helm rollback` walks them. Two separate
# doors can repoint those names at code main never published —
#
#   1. a re-run on main whose VERSION still names an ALREADY-released semver
#      (this is what moved :0.1.20 off the commit v0.1.20 was cut from on
#      2026-08-21, which also made `helm rollback` to :0.1.20 roll back to
#      the WRONG image), and
#   2. a `workflow_dispatch`, which this workflow accepts from ANY ref — so a
#      topic-branch build would otherwise publish :latest and :<version> from
#      branch code, and cut a v<version> release pointing at a branch commit.
#
# Both doors are decided HERE, once, and the build step and the release step
# both read this answer instead of re-deriving it, so the two can never
# disagree about what this run is allowed to move.
#
# Off the default branch the ONLY name published is branch-scoped and carries
# the commit, so it cannot collide with a released name. The dispatch `tag`
# input is deliberately IGNORED there: honouring it would hand the fence's
# own key to the caller, who could simply pass `latest`.
#
# Inputs (environment):
#   GITHUB_REF, GITHUB_REF_NAME, GITHUB_SHA   — set by Actions
#   ECR_REGISTRY, ECR_REPOSITORY              — workflow env
#   INPUT_TAG                                 — dispatch override (main only)
#   DEFAULT_BRANCH                            — defaults to `main`
# Reads ./VERSION and the local tag database (checkout uses fetch-depth: 0,
# so the tag lookup is local and costs no API call).
#
# Writes `key=value` lines on stdout; the caller appends them to $GITHUB_OUTPUT.
set -euo pipefail

emit_tags() {
  local version short_sha image_base primary released tags is_main safe_ref

  # Most repos keep the version in a ./VERSION file. Where an earlier job
  # computes it instead (a version-management job that bumps and outputs it),
  # the caller passes it in rather than this script guessing a second source.
  version="${VERSION_VALUE:-}"
  # VERSION_FILE: a repo that builds more than one image keeps a VERSION file
  # per image (e.g. ops/<component>/VERSION), so the path is not always ./VERSION.
  [ -n "$version" ] || version="$(tr -d '[:space:]' < "${VERSION_FILE:-VERSION}")"
  version="$(printf '%s' "$version" | tr -d '[:space:]')"
  if [ -z "$version" ]; then
    echo "prepare-image-tags: version is empty (VERSION_VALUE unset and ./VERSION empty)" >&2
    return 1
  fi

  short_sha="$(printf '%s' "${GITHUB_SHA:?GITHUB_SHA is required}" | cut -c1-7)"
  image_base="${ECR_REGISTRY:?ECR_REGISTRY is required}/${ECR_REPOSITORY:?ECR_REPOSITORY is required}"

  if [ "${GITHUB_REF:?GITHUB_REF is required}" = "refs/heads/${DEFAULT_BRANCH:-main}" ]; then
    is_main=true
  else
    is_main=false
  fi

  if [ "$is_main" = true ]; then
    primary="${INPUT_TAG:-}"
    if [ -n "$primary" ]; then
      # 🔴 INPUT_TAG cagirandan gelen SERBEST METIN ve bu betigin kendi basligi
      # onu "tek seferlik build" diye tarif ediyor. Dogrulanmadigi surece o
      # tarif YANLISTI: olculdu, `INPUT_TAG=0.2.0` (v0.2.0 YAYIMLANMIS iken)
      # `:0.2.0`i yeni kodun ustune tasiyordu -- yani bu dosyanin basliginda
      # "kapattik" diye yazan 1. KAPI hala acikti. `INPUT_TAG` icine virgul
      # koymak da etiket listesine ikinci bir ad enjekte ediyordu.
      case "$primary" in
        *,*|*" "*|*"$(printf '\t')"*)
          echo "prepare-image-tags: INPUT_TAG must be a single tag (no comma/space): $primary" >&2
          return 1 ;;
      esac
      case "$primary" in
        [A-Za-z0-9_]*) : ;;
        *) echo "prepare-image-tags: INPUT_TAG is not a legal image tag: $primary" >&2; return 1 ;;
      esac
      if [ -n "$(printf '%s' "$primary" | tr -d 'A-Za-z0-9_.-')" ]; then
        echo "prepare-image-tags: INPUT_TAG has characters outside [A-Za-z0-9_.-]: $primary" >&2
        return 1
      fi
      for reserved in latest test; do
        if [ "$primary" = "$reserved" ]; then
          echo "prepare-image-tags: INPUT_TAG may not be the reserved channel '$reserved'" >&2
          return 1
        fi
      done
      if git rev-parse -q --verify "refs/tags/${RELEASE_TAG_PREFIX:-v}${primary}" >/dev/null; then
        echo "prepare-image-tags: INPUT_TAG '$primary' names an ALREADY RELEASED version" >&2
        echo "  (${RELEASE_TAG_PREFIX:-v}${primary} exists). Publishing it here would move a released" >&2
        echo "  name onto different code — the exact failure this gate exists to prevent." >&2
        return 1
      fi
    fi
    if [ -z "$primary" ]; then
      if [ "${VERSION_SOURCE:-file}" = "allocated" ]; then
        # An upstream job allocated this version FOR THIS RUN, so the version is
        # this build's identity: it is the primary tag and `image_url` names it.
        # Making the short SHA primary here silently changed `image_url` from
        # `:<version>` to `:<sha>` for every caller that reports or pins it.
        primary="$version"
      else
        # With a checked-in VERSION file the same commit can be rebuilt at the
        # same version, so the per-run identity is the commit, not the version.
        primary="$short_sha"
      fi
    fi

    # A version carrying the test marker names a test channel, not a release:
    # it moves `:test` and must never touch `:latest` or cut a release.
    if [ -n "${TEST_MARKER:-}" ] && case "$version" in *"$TEST_MARKER"*) true ;; *) false ;; esac; then
      released=true
      tags="${image_base}:${primary}"
      # `<version>` only when it is not already the primary tag — an allocated
      # version would otherwise appear twice in the list.
      [ "$primary" = "$version" ] || tags="${tags},${image_base}:${version}"
      tags="${tags},${image_base}:test"
    elif [ "${VERSION_SOURCE:-file}" = "allocated" ] \
         || ! git rev-parse -q --verify "refs/tags/${RELEASE_TAG_PREFIX:-v}${version}" >/dev/null; then
      # Two genuinely different situations, not one with an exception:
      #
      #   file      — the version is read from a checked-in VERSION file, so
      #               re-running an old commit offers the SAME version again.
      #               An existing v<version> means somebody else already
      #               published it, and re-pushing :<version> would move a
      #               released name onto different code.
      #   allocated — an upstream job in THIS run picked the version and proved
      #               it free before taking it. The tag exists because we just
      #               created it, so the collision guard would suppress exactly
      #               the tags the run exists to publish.
      released=false
      tags="${image_base}:${primary}"
      [ "$primary" = "$version" ] || tags="${tags},${image_base}:${version}"
      tags="${tags},${image_base}:latest"
    else
      released=true
      tags="${image_base}:${primary}"
    fi

    # EXTRA_TAGS: additional names a caller publishes alongside the semver
    # (e.g. a runtime-qualified `node18-<version>`). They are default-branch
    # names like the rest, so they are appended HERE and never on the branch
    # path — a branch build must not create a name that claims a version it
    # did not release.
    # 🔴 DONMUS durumda ek ad EKLENMEZ. Olculdu: `EXTRA_TAGS=latest`, yayimlanmis
    # semver dondurulmusken `:latest`i yine basiyordu -- donmayi tam da onu
    # korumak icin koydugumuz yerden deliyordu.
    if [ -n "${EXTRA_TAGS:-}" ] && [ "$released" != true ]; then
      local extra rest
      rest="$EXTRA_TAGS"
      while [ -n "$rest" ]; do
        extra="${rest%%,*}"
        [ "$extra" = "$rest" ] && rest="" || rest="${rest#*,}"
        extra="$(printf '%s' "$extra" | tr -d '[:space:]')"
        # Ayrilmis kanal adlari EXTRA_TAGS uzerinden gecemez.
        case "$extra" in
          latest|test)
            echo "prepare-image-tags: EXTRA_TAGS may not contain the reserved channel '$extra'" >&2
            return 1 ;;
        esac
        [ -n "$extra" ] && tags="${tags},${image_base}:${extra}"
      done
    fi
  else
    # An image tag must match [A-Za-z0-9_][A-Za-z0-9._-]{0,127}; branch names
    # routinely carry `/`, so fold every character outside that set to `-`.
    safe_ref="$(printf '%s' "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}" \
      | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-64)"
    primary="br-${safe_ref}-${short_sha}"
    released=true
    tags="${image_base}:${primary}"
  fi

  printf 'version=%s\n'          "$version"
  printf 'short_sha=%s\n'        "$short_sha"
  printf 'primary_tag=%s\n'      "$primary"
  printf 'already_released=%s\n' "$released"
  printf 'is_main=%s\n'          "$is_main"
  printf 'image_url=%s\n'        "${image_base}:${primary}"
  printf 'tags=%s\n'             "$tags"

  # Callers that shell out to `docker buildx build` need the same list as
  # repeated -t flags. Deriving it HERE keeps the two spellings of one
  # decision from drifting apart in a caller's own shell.
  if [ "${TAG_STYLE:-csv}" = "docker-args" ]; then
    printf 'docker_args=%s\n' "$(printf '%s' "$tags" | tr ',' '\n' | sed 's/^/-t /' | tr '\n' ' ' | sed 's/ $//')"
  fi
}

# ---------------------------------------------------------------- self-test
# Each case runs the REAL emit_tags in a REAL throwaway git repo with REAL
# tags, so the production `git rev-parse` path is exercised verbatim — there
# is no test-only branch in the code above to drift away from it.
selftest() {
  local pass=0 fail=0 sandbox _rc _longref
  sandbox="$(mktemp -d)"
  trap 'rm -rf "$sandbox"' RETURN

  # Every per-case variable is passed as an argument and applied as a command
  # PREFIX inside a subshell. An earlier form assigned them in the enclosing
  # shell (`GITHUB_REF=... out="$(...)"` is an assignment-only command, not a
  # prefix), which left each case's values behind for the next one: a case
  # that forgot a variable would silently inherit it and assert against the
  # wrong input while still reporting green.
  _run() { # _run <case> <version> <tag|-> <github_ref> <ref_name> <input_tag>
    local dir="$sandbox/$1"
    mkdir -p "$dir"
    ( cd "$dir"
      git init -q .
      git config user.email ci@example.invalid
      git config user.name ci
      printf '%s\n' "$2" > VERSION
      git add VERSION
      git -c commit.gpgsign=false commit -qm init
      [ "$3" = "-" ] || git tag "$3"
      GITHUB_REF="$4" GITHUB_REF_NAME="$5" INPUT_TAG="$6" emit_tags
    )
  }

  # 🪤 _check ve _refute AYNI eslestiriciyi kullanir. Ayri grep cagrilari
  # tutulursa _refute'nin grep'i bozulunca 17 negatif iddia SESSIZCE gecer ve
  # suit yine "0 failed" der (olculdu: mutasyon M-A, 53/0 rc=0). Tek eslestirici,
  # _check'in pozitif kontrolleriyle birlikte kendini de dogrular.
  _match() { printf '%s' "$2" | grep -qF -- "$1"; }

  _check() { # _check <case> <description> <expect-substring> <haystack>
    if _match "$3" "$4"; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      printf '  FAIL  %s: expected to contain %s\n' "$1: $2" "$3" >&2
      printf '        got: %s\n' "$(printf '%s' "$4" | tr '\n' ' ')" >&2
    fi
  }

  _refute() { # _refute <case> <description> <forbidden-substring> <haystack>
    if _match "$3" "$4"; then
      fail=$((fail + 1))
      printf '  FAIL  %s: must NOT contain %s\n' "$1: $2" "$3" >&2
      printf '        got: %s\n' "$(printf '%s' "$4" | tr '\n' ' ')" >&2
    else
      pass=$((pass + 1))
    fi
  }

  # 🔴 TUR 3 BULGUSU — ALTI mutant bu yuzden hayatta kaldi (M2 released-guard,
  # M11 comma, M12 reserved, M13 empty-version, M14 EXTRA reserved,
  # M15 illegal-char). Hepsi TEK kok neden: ret vakalari `|| true` ile
  # cagriliyordu ve suit yalnizca STDOUT'a bakiyordu. Yani bir ret yolunun
  # `return 1`i `return 0`a donse iddia yine gecerdi.
  #
  # Bunun CI'daki karsiligi sessiz bir yesil: cagiranlar betigi
  # `run: ./scripts/ci/prepare-image-tags.sh >> "$GITHUB_OUTPUT"` diye
  # kosuyor; rc 0 donerse adim YESIL gecer ama `tags=` hic yazilmaz ve
  # asagi akista etiketsiz bir build'e donusur.
  #
  # 🔑 Ret yolunun iddiasi MESAJ DEGIL, CIKIS KODUDUR. Mesaj degisebilir;
  # sozlesme rc'dir.
  _runrc() { # _runrc <_run argumanlari> — `out` ve `_rc` degiskenlerini doldurur
    _rc=0
    out="$(_run "$@" 2>&1)" || _rc=$?
  }
  _rc_is() { # _rc_is <case> <description> <beklenen-rc>
    if [ "$_rc" = "$3" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      printf '  FAIL  %s: cikis kodu %s olmali, %s geldi\n' "$1: $2" "$3" "$_rc" >&2
    fi
  }

  export ECR_REGISTRY=reg.example.invalid ECR_REPOSITORY=sb/app
  export GITHUB_SHA=abcdef1234567890 DEFAULT_BRANCH=main

  local out

  # MAIN-UNRELEASED — the POSITIVE CONTROL for every "no :latest" assertion
  # below: if this case did not itself publish :latest, a passing _refute
  # would prove nothing but a broken search.
  out="$(_run main-unreleased 0.2.0 - refs/heads/main main '')"
  _check MAIN-UNRELEASED ':latest yayimlanir'       'reg.example.invalid/sb/app:latest' "$out"
  _check MAIN-UNRELEASED ':<version> yayimlanir'    'reg.example.invalid/sb/app:0.2.0'  "$out"
  _check MAIN-UNRELEASED 'short sha birincil'       'primary_tag=abcdef1'               "$out"
  _check MAIN-UNRELEASED 'is_main dogru'            'is_main=true'                      "$out"
  _check MAIN-UNRELEASED 'release serbest'          'already_released=false'            "$out"

  # MAIN-RELEASED — VERSION already released: the semver and :latest freeze.
  out="$(_run main-released 0.2.0 v0.2.0 refs/heads/main main '')"
  _refute MAIN-RELEASED ':latest tasinmaz'            'sb/app:latest' "$out"
  _refute MAIN-RELEASED 'yayimlanmis semver ezilmez'  'sb/app:0.2.0'  "$out"
  _check  MAIN-RELEASED 'release atlanir'             'already_released=true' "$out"

  # MAIN-INPUT — a dispatch override on main keeps the old behaviour.
  out="$(_run main-input 0.2.0 - refs/heads/main main hotfix1)"
  _check MAIN-INPUT 'override birincil olur'        'primary_tag=hotfix1' "$out"
  _check MAIN-INPUT 'main hala :latest basar'       'sb/app:latest'       "$out"

  # BRANCH — the fence itself.
  out="$(_run branch 0.2.0 - refs/heads/faz3/arm64-crosscompile faz3/arm64-crosscompile '')"
  _refute BRANCH ':latest BASILMAZ'                 'sb/app:latest'  "$out"
  _refute BRANCH ':<version> BASILMAZ'              'sb/app:0.2.0'   "$out"
  _check  BRANCH 'dal-ozel etiket'                  'sb/app:br-faz3-arm64-crosscompile-abcdef1' "$out"
  _check  BRANCH 'is_main yanlis'                   'is_main=false'  "$out"
  _check  BRANCH 'release bastirilir'               'already_released=true' "$out"
  _refute BRANCH 'egik cizgi etikete sizmaz'        'br-faz3/arm64'  "$out"

  # BRANCH-INPUT-LATEST — the attack: dispatch asks for `latest` off main.
  out="$(_run branch-input latest-bait - refs/heads/topic topic latest)"
  _refute BRANCH-INPUT 'dispatch :latest calamaz'   'sb/app:latest' "$out"
  _check  BRANCH-INPUT 'dal etiketine dusurulur'    'sb/app:br-topic-abcdef1' "$out"

  # TAG-REF — a tag push is not the default branch either.
  out="$(_run tagref 0.2.0 - refs/tags/v9.9.9 v9.9.9 '')"
  _refute TAG-REF ':latest BASILMAZ'                'sb/app:latest' "$out"
  _check  TAG-REF 'dal-ozel etiket'                 'sb/app:br-v9.9.9-abcdef1' "$out"

  # NO-LEAK — proves the prefix form actually isolates: this case supplies an
  # EMPTY input tag right after BRANCH-INPUT set it to `latest`. Under the old
  # assignment-only form the stale `latest` would survive into here.
  out="$(_run no-leak 0.2.0 - refs/heads/main main '')"
  _check NO-LEAK 'onceki INPUT_TAG sizmadi'         'primary_tag=abcdef1' "$out"
  _refute NO-LEAK 'bayat latest birincil olmadi'    'primary_tag=latest'  "$out"

  # VERSION-VALUE — the version may arrive from an upstream job instead of
  # a file. The sandbox repo's own VERSION file says 0.2.0, so a passing
  # assertion on 9.9.9 proves the override actually won.
  out="$(VERSION_VALUE=9.9.9 _run version-value 0.2.0 - refs/heads/main main '')"
  _check VERSION-VALUE 'gecersiz kilma kazanir'     'version=9.9.9'      "$out"
  _refute VERSION-VALUE 'dosyadaki surum kullanilmadi' 'sb/app:0.2.0'    "$out"

  # VERSION-FILE — a second image in the same repo keeps its own VERSION file.
  # The sandbox writes 0.2.0 to ./VERSION; the nested file says 3.3.3, so a
  # passing assertion on 3.3.3 proves the path was honoured and not ignored.
  ( mkdir -p "$sandbox/vfile-src" && printf '3.3.3\n' > "$sandbox/vfile-src/V" ) 
  out="$(VERSION_FILE="$sandbox/vfile-src/V" _run version-file 0.2.0 - refs/heads/main main '')"
  _check  VERSION-FILE 'ic ice yol okundu'          'version=3.3.3' "$out"
  _refute VERSION-FILE 'kok VERSION kullanilmadi'   'sb/app:0.2.0'  "$out"

  # TEST-MARKER — a test-channel version moves :test, never :latest.
  out="$(VERSION_VALUE=1.2.3-test-abc TEST_MARKER=-test- _run test-marker 0.2.0 - refs/heads/main main '')"
  _check  TEST-MARKER ':test basilir'               'sb/app:test'   "$out"
  _refute TEST-MARKER ':latest BASILMAZ'            'sb/app:latest' "$out"
  _check  TEST-MARKER 'release bastirilir'          'already_released=true' "$out"

  # TEST-MARKER-BRANCH — the branch fence still wins over the test channel.
  out="$(VERSION_VALUE=1.2.3-test-abc TEST_MARKER=-test- _run test-marker-br 0.2.0 - refs/heads/topic topic '')"
  _refute TEST-MARKER-BRANCH ':test de BASILMAZ'    'sb/app:test'   "$out"
  _check  TEST-MARKER-BRANCH 'dal etiketi'          'sb/app:br-topic-abcdef1' "$out"

  # ALLOCATED — v0.2.0 EXISTS in this sandbox, yet the version was allocated
  # by an upstream job in this run, so :latest and :0.2.0 must still publish.
  # MAIN-RELEASED above is the counterpart: same tag present, `file` source,
  # tags suppressed. The pair is what proves the distinction is load-bearing.
  out="$(VERSION_SOURCE=allocated _run allocated 0.2.0 v0.2.0 refs/heads/main main '')"
  _check ALLOCATED ':latest yine basilir'           'sb/app:latest' "$out"
  _check ALLOCATED ':<version> yine basilir'        'sb/app:0.2.0'  "$out"
  _check ALLOCATED 'release serbest'                'already_released=false' "$out"

  _count() { printf '%s' "$1" | sed -n 's/^tags=//p' | tr ',' '\n' | grep -c . ; }
  _check ALLOCATED 'image_url SURUMU gosterir'      'image_url=reg.example.invalid/sb/app:0.2.0' "$out"
  _check ALLOCATED 'birincil etiket surum'          'primary_tag=0.2.0' "$out"
  _refute ALLOCATED 'kisa sha etiketi EKLENMEDI'    'sb/app:abcdef1' "$out"
  if [ "$(_count "$out")" = "2" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf '  FAIL  ALLOCATED: etiket sayisi 2 olmali, %s\n' "$(_count "$out")" >&2; fi

  # ALLOCATED-BRANCH — allocation does not buy a way past the branch fence.
  out="$(VERSION_SOURCE=allocated _run allocated-br 0.2.0 v0.2.0 refs/heads/topic topic '')"
  _refute ALLOCATED-BRANCH ':latest BASILMAZ'       'sb/app:latest' "$out"
  _check  ALLOCATED-BRANCH 'dal etiketi'            'sb/app:br-topic-abcdef1' "$out"

  # EXTRA-TAGS — caller-supplied extra names ride along on main only.
  out="$(EXTRA_TAGS='node18-0.2.0, qa' _run extra-tags 0.2.0 - refs/heads/main main '')"
  _check EXTRA-TAGS 'ek etiket eklendi'             'sb/app:node18-0.2.0' "$out"
  _check EXTRA-TAGS 'bosluk kirpildi'               'sb/app:qa'           "$out"
  _check EXTRA-TAGS 'asil etiketler duruyor'        'sb/app:latest'       "$out"

  # EXTRA-TAGS-BRANCH — the branch fence outranks them, as it does every knob.
  out="$(EXTRA_TAGS='node18-0.2.0' _run extra-tags-br 0.2.0 - refs/heads/topic topic '')"
  _refute EXTRA-TAGS-BRANCH 'dalda ek etiket YOK'   'sb/app:node18-0.2.0' "$out"
  _check  EXTRA-TAGS-BRANCH 'yalniz dal etiketi'    'tags=reg.example.invalid/sb/app:br-topic-abcdef1' "$out"

  # ALT-DEFAULT-BRANCH — this script is called by reusable workflows with MORE
  # THAN ONE caller: a main pipeline publishing from `main`, and a test
  # pipeline publishing the `:test` channel from `test`. Treating `main` as
  # the only publishing branch silently stopped the second caller from
  # publishing the very tags its own deploy job pins, which is an
  # ImagePullBackOff on the next push to that branch. The pair below is the
  # proof: the SAME ref publishes the channel under its own default branch and
  # is fenced under the other one.
  out="$(DEFAULT_BRANCH=test VERSION_VALUE=9.9.9-test-1 TEST_MARKER=-test- VERSION_SOURCE=allocated \
    _run alt-default 0.2.0 - refs/heads/test test '')"
  _check ALT-DEFAULT 'kendi dalinda kanal yayimlanir' 'sb/app:test'      "$out"
  _check ALT-DEFAULT 'surum etiketi de yayimlanir'    'sb/app:9.9.9-test-1' "$out"
  _check ALT-DEFAULT 'is_main dogru'                  'is_main=true'    "$out"
  out="$(DEFAULT_BRANCH=main VERSION_VALUE=9.9.9-test-1 TEST_MARKER=-test- VERSION_SOURCE=allocated \
    _run alt-default-b 0.2.0 - refs/heads/test test '')"
  _refute ALT-DEFAULT-OTHER 'baska varsayilanda kanal YOK' 'sb/app:test' "$out"
  _check  ALT-DEFAULT-OTHER 'dal etiketine duser'          'sb/app:br-test-abcdef1' "$out"

  # DOCKER-ARGS — same decision, -t spelling.
  out="$(TAG_STYLE=docker-args _run docker-args 0.2.0 - refs/heads/topic topic '')"
  _check  DOCKER-ARGS '-t bayragi uretilir'         'docker_args=-t reg.example.invalid/sb/app:br-topic-abcdef1' "$out"
  _refute DOCKER-ARGS 'docker_args da latest yok'   'sb/app:latest' "$out"
  # POZITIF KONTROL: main'de docker_args GERCEKTEN cok etiketli olur, yoksa
  # yukaridaki "latest yok" iddiasi bos bir dizgeyi olcuyor olabilirdi.
  out="$(TAG_STYLE=docker-args _run docker-args-main 0.2.0 - refs/heads/main main '')"
  _check  DOCKER-ARGS-MAIN 'main cok etiketli'      '-t reg.example.invalid/sb/app:latest' "$out"

  # ---- 3. GÖZ BULGULARI: aşağıdaki her vaka ÖLÇÜLMÜŞ bir deliği çiviler ----

  # MAIN-PREFIX — `main` ile BASLAYAN ama `main` OLMAYAN ref. Betik bunu zaten
  # dogru yapiyordu, ama hicbir test civilemiyordu: onek eslesmesine ceviren
  # mutant 53/0 ile HAYATTA kaliyordu.
  # INPUT_TAG olarak ZARARSIZ bir ad veriliyor: `latest` verilseydi onek-mutantı
  # main koluna dusup ayrilmis-kanal reddine takilir ve suit COKEREK olurdu --
  # yakalanirdi ama gerekcesi "iddia dustu" degil "cokti" olurdu.
  out="$(_run main-prefix 0.2.0 - refs/heads/main-yedek main-yedek hotfix9)"
  _refute MAIN-PREFIX ':latest BASILMAZ'            'sb/app:latest' "$out"
  _refute MAIN-PREFIX ':<surum> BASILMAZ'           'sb/app:0.2.0'  "$out"
  _check  MAIN-PREFIX 'dal etiketine duser'         'sb/app:br-main-yedek-abcdef1' "$out"

  # TAG-LEN — uzun dal adi etiket sinirini asmamali (128). Kirpmayi kaldiran
  # mutant da testsizdi.
  # 🪤 SC2046: `$(seq ...)` tirnaksiz birakilmisti (bu oturumda ben ekledim).
  # Uzun adi bir degiskende uretip tirnakli gecmek hem lint'i kapatir hem de
  # ayni dizgenin iki kez uretilmesini onler.
  _longref="$(printf 'x%.0s' $(seq 1 90))"
  out="$(_run tag-len 0.2.0 - "refs/heads/$_longref" "$_longref" '')"
  if [ "$(printf '%s' "$out" | sed -n 's/^primary_tag=//p' | wc -c)" -le 80 ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); printf '  FAIL  TAG-LEN: birincil etiket cok uzun\n' >&2
  fi

  # INPUT-TAG-RELEASED — bu dosyanin basliginda "kapattik" yazan 1. KAPI.
  _runrc input-released 0.2.0 v0.9.9 refs/heads/main main 0.9.9
  _check  INPUT-RELEASED 'yayimlanmis surum REDDEDILIR' 'ALREADY RELEASED' "$out"
  _refute INPUT-RELEASED 'etiket URETILMEZ'             'tags=' "$out"
  _rc_is  INPUT-RELEASED 'cikis kodu 1' 1
  # POZITIF KONTROL: yayimlanmamis bir INPUT_TAG hala GECMELI, yoksa yukaridaki
  # iddia "her INPUT_TAG'i reddet" ile de gecerdi.
  _runrc input-free 0.2.0 - refs/heads/main main hotfix9
  _check INPUT-FREE 'yayimlanmamis override gecer'  'primary_tag=hotfix9' "$out"
  # 🪤 rc=0 POZITIF KONTROLU: bu olmadan "rc 1 bekle" iddialari, betik HER
  # girdide 1 dondurse bile gecerdi.
  _rc_is INPUT-FREE 'basarili yol rc=0' 0

  # INPUT-TAG-RESERVED / INJECTION
  _runrc input-reserved 0.2.0 - refs/heads/main main latest
  _check INPUT-RESERVED 'ayrilmis kanal REDDEDILIR'  'reserved channel' "$out"
  _rc_is INPUT-RESERVED 'cikis kodu 1' 1
  _runrc input-comma 0.2.0 - refs/heads/main main 'x,reg.example.invalid/sb/app:latest'
  _check  INPUT-COMMA 'virgul enjeksiyonu REDDEDILIR' 'single tag' "$out"
  _rc_is  INPUT-COMMA 'cikis kodu 1' 1
  # 🪤 Burada 'sb/app:latest' aramak YANLIS olurdu: ret MESAJI reddedilen girdiyi
  # yankiliyor ve arama ona takiliyor. Dogru iddia: hic etiket URETILMEDI.
  _refute INPUT-COMMA 'hic etiket uretilmedi'         'tags=' "$out"

  # EXTRA-TAGS-FROZEN — donmus durumda ek ad EKLENMEZ.
  out="$(EXTRA_TAGS=qa _run extra-frozen 0.2.0 v0.2.0 refs/heads/main main '')"
  _refute EXTRA-FROZEN 'donmusken ek ad YOK'        'sb/app:qa'     "$out"
  _check  EXTRA-FROZEN 'yalniz birincil'            'tags=reg.example.invalid/sb/app:abcdef1' "$out"
  EXTRA_TAGS=latest _runrc extra-reserved 0.2.0 - refs/heads/main main ''
  _check EXTRA-RESERVED 'EXTRA_TAGS ayrilmis ad REDDEDILIR' 'reserved channel' "$out"
  _rc_is EXTRA-RESERVED 'cikis kodu 1' 1

  # 🔴 TUR 3'te EKLENEN UC YENI VAKA — bu ret yollarinin HIC iddiasi yoktu
  # (mutant M13/M15 hayatta kalmisti). Kapilar calisiyordu; eksik olan testti.
  _runrc empty-version '' - refs/heads/main main ''
  _check EMPTY-VERSION 'bos VERSION REDDEDILIR' 'version is empty' "$out"
  _refute EMPTY-VERSION 'hic etiket uretilmedi' 'tags=' "$out"
  _rc_is EMPTY-VERSION 'cikis kodu 1' 1

  _runrc input-badfirst 0.2.0 - refs/heads/main main '-dash'
  _check INPUT-BADFIRST 'ilk karakter harf/rakam DEGILSE REDDEDILIR' 'not a legal image tag' "$out"
  _rc_is INPUT-BADFIRST 'cikis kodu 1' 1

  _runrc input-badchar 0.2.0 - refs/heads/main main 'a/b'
  # 🪤 Ilk yazisimda burada 'not a legal image tag' bekledim ve suit BUNU YAKALADI:
  # 'a/b' ILK KARAKTER kapisini gecer (a harf), KARAKTER-KUMESI kapisina takilir.
  # Iki AYRI ret yolu, iki AYRI mesaj — testin degeri tam da bu ayrimi tutmasi.
  _check INPUT-BADCHAR 'izinsiz karakter REDDEDILIR' 'characters outside' "$out"
  _rc_is INPUT-BADCHAR 'cikis kodu 1' 1

  # RELEASE-TAG-PREFIX — ikinci imajin KENDI release ad-uzayi. Onek olmadan
  # reconciler, gateway'in v<surum> uzayina bakip hic yapmadigi bir release
  # yuzunden dondurulurdu.
  out="$(RELEASE_TAG_PREFIX=eip-reconciler-v _run prefix 0.2.0 v0.2.0 refs/heads/main main '')"
  _check  RELEASE-PREFIX 'baska uzaydaki tag DONDURMAZ' 'sb/app:latest' "$out"
  out="$(RELEASE_TAG_PREFIX=eip-reconciler-v _run prefix2 0.2.0 eip-reconciler-v0.2.0 refs/heads/main main '')"
  _refute RELEASE-PREFIX2 'KENDI uzayindaki tag DONDURUR' 'sb/app:latest' "$out"

  printf '=== prepare-image-tags --selftest: %d passed, %d failed ===\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest ;;
  '')         emit_tags ;;
  *)          echo "usage: $0 [--selftest]" >&2; exit 2 ;;
esac
