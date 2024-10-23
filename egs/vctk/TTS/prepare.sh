#!/usr/bin/env bash

# fix segmentation fault reported in https://github.com/k2-fsa/icefall/issues/674
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

set -eou pipefail

stage=0
stop_stage=100
use_edinburgh_vctk_url=true

dl_dir=$PWD/download

. shared/parse_options.sh || exit 1

# All files generated by this script are saved in "data".
# You can safely remove "data" and rerun this script to regenerate it.
mkdir -p data

log() {
  # This function is from espnet
  local fname=${BASH_SOURCE[1]##*/}
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') (${fname}:${BASH_LINENO[0]}:${FUNCNAME[1]}) $*"
}

log "dl_dir: $dl_dir"

if [ $stage -le -1 ] && [ $stop_stage -ge -1 ]; then
  log "Stage -1: build monotonic_align lib"
  if [ ! -d vits/monotonic_align/build ]; then
    cd vits/monotonic_align
    python setup.py build_ext --inplace
    cd ../../
  else 
    log "monotonic_align lib already built"
  fi
fi

if [ $stage -le 0 ] && [ $stop_stage -ge 0 ]; then
  log "Stage 0: Download data"

  # If you have pre-downloaded it to /path/to/VCTK,
  # you can create a symlink
  #
  #   ln -sfv /path/to/VCTK $dl_dir/VCTK
  #
  if [ ! -d $dl_dir/VCTK ]; then
    lhotse download vctk --use-edinburgh-vctk-url ${use_edinburgh_vctk_url} $dl_dir
  fi
fi

if [ $stage -le 1 ] && [ $stop_stage -ge 1 ]; then
  log "Stage 1: Prepare VCTK manifest"
  # We assume that you have downloaded the VCTK corpus
  # to $dl_dir/VCTK
  mkdir -p data/manifests
  if [ ! -e data/manifests/.vctk.done ]; then
    lhotse prepare vctk --use-edinburgh-vctk-url ${use_edinburgh_vctk_url} $dl_dir/VCTK data/manifests
    touch data/manifests/.vctk.done
  fi
fi

if [ $stage -le 2 ] && [ $stop_stage -ge 2 ]; then
  log "Stage 2: Compute spectrogram for VCTK"
  mkdir -p data/spectrogram
  if [ ! -e data/spectrogram/.vctk.done ]; then
    ./local/compute_spectrogram_vctk.py
    touch data/spectrogram/.vctk.done
  fi

  if [ ! -e data/spectrogram/.vctk-validated.done ]; then
    log "Validating data/fbank for VCTK"
    ./local/validate_manifest.py \
      data/spectrogram/vctk_cuts_all.jsonl.gz
    touch data/spectrogram/.vctk-validated.done
  fi
fi

if [ $stage -le 3 ] && [ $stop_stage -ge 3 ]; then
  log "Stage 3: Prepare phoneme tokens for VCTK"
  # We assume you have installed piper_phonemize and espnet_tts_frontend.
  # If not, please install them with:
  #   - piper_phonemize: 
  #       refer to https://github.com/rhasspy/piper-phonemize,
  #       could install the pre-built wheels from https://github.com/csukuangfj/piper-phonemize/releases/tag/2023.12.5
  #   - espnet_tts_frontend: 
  #       `pip install espnet_tts_frontend`, refer to https://github.com/espnet/espnet_tts_frontend/
  if [ ! -e data/spectrogram/.vctk_with_token.done ]; then
    ./local/prepare_tokens_vctk.py
    mv data/spectrogram/vctk_cuts_with_tokens_all.jsonl.gz \
      data/spectrogram/vctk_cuts_all.jsonl.gz
    touch data/spectrogram/.vctk_with_token.done
  fi
fi

if [ $stage -le 4 ] && [ $stop_stage -ge 4 ]; then
  log "Stage 4: Split the VCTK cuts into train, valid and test sets"
  if [ ! -e data/spectrogram/.vctk_split.done ]; then
    lhotse subset --last 600 \
      data/spectrogram/vctk_cuts_all.jsonl.gz \
      data/spectrogram/vctk_cuts_validtest.jsonl.gz
    lhotse subset --first 100 \
      data/spectrogram/vctk_cuts_validtest.jsonl.gz \
      data/spectrogram/vctk_cuts_valid.jsonl.gz
    lhotse subset --last 500 \
      data/spectrogram/vctk_cuts_validtest.jsonl.gz \
      data/spectrogram/vctk_cuts_test.jsonl.gz

    rm data/spectrogram/vctk_cuts_validtest.jsonl.gz

    n=$(( $(gunzip -c data/spectrogram/vctk_cuts_all.jsonl.gz | wc -l) - 600 ))
    lhotse subset --first $n  \
      data/spectrogram/vctk_cuts_all.jsonl.gz \
      data/spectrogram/vctk_cuts_train.jsonl.gz
      touch data/spectrogram/.vctk_split.done
  fi
fi

if [ $stage -le 5 ] && [ $stop_stage -ge 5 ]; then
  log "Stage 5: Generate token file"
  # We assume you have installed piper_phonemize and espnet_tts_frontend.
  # If not, please install them with:
  #   - piper_phonemize: 
  #       refer to https://github.com/rhasspy/piper-phonemize,
  #       could install the pre-built wheels from https://github.com/csukuangfj/piper-phonemize/releases/tag/2023.12.5
  #   - espnet_tts_frontend: 
  #       `pip install espnet_tts_frontend`, refer to https://github.com/espnet/espnet_tts_frontend/
  if [ ! -e data/tokens.txt ]; then
    ./local/prepare_token_file.py --tokens data/tokens.txt
  fi
fi

if [ $stage -le 6 ] && [ $stop_stage -ge 6 ]; then
  log "Stage 6: Generate speakers file"
  if [ ! -e data/speakers.txt ]; then
    gunzip -c data/manifests/vctk_supervisions_all.jsonl.gz \
      | jq '.speaker' | sed 's/"//g' \
      | sort | uniq > data/speakers.txt
  fi
fi
