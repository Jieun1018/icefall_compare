#!/usr/bin/env bash

# fix segmentation fault reported in https://github.com/k2-fsa/icefall/issues/674
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

set -eou pipefail

nj=15
stage=-1
stop_stage=100
export CUDA_VISIBLE_DEVICES=""

# We assume dl_dir (download dir) contains the following
# directories and files. If not, they will be downloaded
# by this script automatically.
#
#  - $dl_dir/librilight
#      You can find small, medium, large, etc. inside it.
#
#  - $dl_dir/libriheavy
#      You can find libriheavy_cuts_small.jsonl.gz, libriheavy_cuts_medium.jsonl.gz, etc. inside it.
#
#  - $dl_dir/musan
#      This directory contains the following directories downloaded from
#       http://www.openslr.org/17/
#
#     - music
#     - noise
#     - speech
dl_dir=$PWD/download

# If you want to do PromptASR experiments, please set it to True
# as this will keep the texts and pre_text information required for
# the training of PromptASR.
keep_custom_fields=False

. shared/parse_options.sh || exit 1

# vocab size for sentence piece models.
# It will generate data/lang_bpe_xxx,
# data/lang_bpe_yyy if the array contains xxx, yyy
vocab_sizes=(
  # 5000
  # 2000
  # 1000
  500
)

# All files generated by this script are saved in "data".
# You can safely remove "data" and rerun this script to regenerate it.
mkdir -p data
fbank_dir=data/fbank
manifests_dir=data/manifests

log() {
  # This function is from espnet
  local fname=${BASH_SOURCE[1]##*/}
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') (${fname}:${BASH_LINENO[0]}:${FUNCNAME[1]}) $*"
}

log "dl_dir: $dl_dir"

if [ $stage -le -1 ] && [ $stop_stage -ge -1 ]; then
  log "Stage -1: Download audio data."
  # If you have pre-downloaded it to /path/to/librilight,
  # you can create a symlink
  #
  #   ln -sfv /path/to/librilight $dl_dir/librilight
  #
  mkdir -p $dl_dir/librilight
  for subset in small medium large; do
    log "Downloading ${subset} subset."
    if [ ! -d $dl_dir/librilight/${subset} ]; then
      wget -P $dl_dir/librilight -c https://dl.fbaipublicfiles.com/librilight/data/${subset}.tar 
      tar xf $dl_dir/librilight/${subset}.tar -C $dl_dir/librilight
    else
      log "Skipping download, ${subset} subset exists."
    fi
  done
fi

if [ $stage -le 0 ] && [ $stop_stage -ge 0 ]; then
  log "Stage 0: Download manifests from huggingface."

  # If you have pre-downloaded it to /path/to/libriheavy,
  # you can create a symlink
  #
  #   ln -sfv /path/to/libriheavy $dl_dir/libriheavy
  #
  mkdir -p $dl_dir/libriheavy
  for subset in small medium large dev test_clean test_other; do
    if [ ! -e $dl_dir/libriheavy/libriheavy_cuts_${subset}.jsonl.gz ]; then
      log "Downloading ${subset} subset."
      wget -P $dl_dir/libriheavy -c https://huggingface.co/datasets/pkufool/libriheavy/resolve/main/libriheavy_cuts_${subset}.jsonl.gz
    else
      log "Skipping download, ${subset} subset exists."
    fi
  done

  # If you have pre-downloaded it to /path/to/musan,
  # you can create a symlink
  #
  #   ln -sfv /path/to/musan $dl_dir/
  #
  if [ ! -d $dl_dir/musan ]; then
    lhotse download musan $dl_dir
  fi
fi

if [ $stage -le 1 ] && [ $stop_stage -ge 1 ]; then
  log "Stage 1: Download manifests from modelscope"
  mkdir -p $dl_dir/libriheavy
  if [ ! -e $dl_dir/libriheavy/libriheavy_cuts_small.jsonl.gz ]; then
      cd $dl_dir/libriheavy
      GIT_LFS_SKIP_SMUDGE=1 git clone https://www.modelscope.cn/datasets/pkufool/Libriheavy.git
      cd Libriheavy
      git lfs pull --exclude "raw/*"
      mv *.jsonl.gz ../
      cd ..
      rm -rf Libriheavy
      cd ../../
  fi
fi

if [ $stage -le 2 ] && [ $stop_stage -ge 2 ]; then
  log "Stage 2: Prepare musan manifest"
  # We assume that you have downloaded the musan corpus
  # to $dl_dir/musan
  mkdir -p $manifests_dir
  if [ ! -e $manifests_dir/.musan.done ]; then
    lhotse prepare musan $dl_dir/musan $manifests_dir
    touch $manifests_dir/.musan.done
  fi
fi

if [ $stage -le 3 ] && [ $stop_stage -ge 3 ]; then
  log "Stage 3: Prepare Libriheavy manifests"
  mkdir -p $manifests_dir
  for subset in small medium large dev test_clean test_other; do
    if [ ! -e $manifests_dir/libriheavy_cuts_${subset}.jsonl.gz ]; then
      log "Prepare manifest for subset : ${subset}"
      ./local/prepare_manifest.py $dl_dir/libriheavy/libriheavy_cuts_${subset}.jsonl.gz $manifests_dir $keep_custom_fields
    fi
  done
fi

if [ $stage -le 4 ] && [ $stop_stage -ge 4 ]; then
  log "Stage 4: Compute fbank for musan"
  mkdir -p $fbank_dir
  if [ ! -e $fbank_dir/.musan.done ]; then
    ./local/compute_fbank_musan.py
    touch $fbank_dir/.musan.done
  fi
fi

if [ $stage -le 5 ] && [ $stop_stage -ge 5 ]; then
  log "Stage 5: Compute fbank for small subset and validation subsets"
  for subset in test_clean test_other dev small; do
    log "Computing $subset subset."
    if [ ! -e $fbank_dir/.libriheavy.${subset}.done ]; then
      ./local/compute_fbank_libriheavy.py \
        --manifest-dir ${manifests_dir} \
        --subset ${subset} \
        --fbank-dir $fbank_dir \
        --num-workers $nj
    fi
  done
fi

num_per_split=8000
if [ $stage -le 6 ] && [ $stop_stage -ge 6 ]; then
  log "Stage 6: Split medium and large subsets."
  for subset in medium large; do
    log "Spliting subset : $subset"
    split_dir=$manifests_dir/libriheavy_${subset}_split
    mkdir -p $split_dir
    if [ ! -e $split_dir/.split_completed ]; then
      lhotse split-lazy $manifests_dir/libriheavy_cuts_${subset}.jsonl.gz $split_dir $num_per_split
      touch $split_dir/.split_completed
    fi
  done
fi

if [ $stage -le 7 ] && [ $stop_stage -ge 7 ]; then
  log "Stage 7: Compute fbank for medium and large subsets"
  mkdir -p $fbank_dir
  chunk_size=20
  for subset in medium large; do
    if [ $subset == "large" ]; then
      chunk_size=200
    fi
    num_splits=$(find $manifests_dir/libriheavy_${subset}_split -name "libriheavy_cuts_${subset}.*.jsonl.gz" | wc -l)
    if [ ! -e $fbank_dir/.libriheavy.${subset}.done ]; then
      for i in $(seq 0 1 6); do
        start=$(( i * $chunk_size ))
        end=$(( (i+1) * $chunk_size ))
        ./local/compute_fbank_libriheavy.py \
          --manifest-dir ${manifests_dir} \
          --use-splits 1 \
          --subset ${subset} \
          --fbank-dir $fbank_dir \
          --num-splits $num_splits \
          --num-workers $nj \
          --start $start \
          --stop $end &
      done
      wait
      touch $fbank_dir/.libriheavy.${subset}.done
    fi
  done
fi

if [ $stage -le 8 ] && [ $stop_stage -ge 8 ]; then
  log "Stage 8: Combine features for medium and large subsets."
  for subset in medium large; do
    log "Combining $subset subset."
    if [ ! -f $fbank_dir/libriheavy_cuts_${subset}.jsonl.gz ]; then
      pieces=$(find $fbank_dir/libriheavy_${subset}_split -name "libriheavy_cuts_${subset}.*.jsonl.gz")
      lhotse combine $pieces $fbank_dir/libriheavy_cuts_${subset}.jsonl.gz
    fi
  done
fi

if [ $stage -le 9 ] && [ $stop_stage -ge 9 ]; then
  log "Stage 9: Train BPE model for normalized text"

  if [ ! -f data/texts ]; then
    gunzip -c $manifests_dir/libriheavy_cuts_medium.jsonl.gz \
      | jq '.supervisions[].text' | sed 's/"//;s/\\//g;s/"$//' \
      | ./local/norm_text.py > data/texts
  fi

  for vocab_size in ${vocab_sizes[@]}; do
    lang_dir=data/lang_bpe_${vocab_size}
    mkdir -p $lang_dir

    cp data/texts $lang_dir/text

    if [ ! -f $lang_dir/bpe.model ]; then
      ./local/train_bpe_model.py \
        --lang-dir $lang_dir \
        --vocab-size $vocab_size \
        --transcript $lang_dir/text
    fi
  done
fi


if [ $stage -le 10 ] && [ $stop_stage -ge 10 ]; then
  log "Stage 10: Train BPE model for unnormalized text"
  if [ ! -f data/punc_texts ]; then
    gunzip -c $manifests_dir/libriheavy_cuts_medium.jsonl.gz \
      | jq '.supervisions[].text' | sed 's/"//;s/\\//g;s/"$//' > data/punc_texts
  fi
  for vocab_size in ${vocab_sizes[@]}; do
    new_vocab_size=$(($vocab_size + 256))
    lang_dir=data/lang_punc_bpe_${new_vocab_size}
    mkdir -p $lang_dir

    cp data/punc_texts $lang_dir/text

    if [ ! -f $lang_dir/bpe.model ]; then
      ./local/train_bpe_model.py \
        --lang-dir $lang_dir \
        --byte-fallback \
        --vocab-size ${new_vocab_size} \
        --byte-fallback \
        --character-coverage 0.99 \
        --transcript $lang_dir/text
    fi
  done
fi

if [ $stage -le 11 ] && [ $stop_stage -ge 11 ]; then
  log "Stage 11: Prepare language model for normalized text"

  for subset in small medium large; do
    if [ ! -f $manifests_dir/texts_${subset} ]; then
      gunzip -c $manifests_dir/libriheavy_cuts_${subset}.jsonl.gz \
        | jq '.supervisions[].text' | sed 's/"//;s/\\//g;s/"$//' \
        | ./local/norm_text.py > $manifests_dir/texts_${subset}
    fi
  done

  mkdir -p data/lm
  if [ ! -f data/lm/text ]; then
    cat $manifests_dir/texts_small $manifests_dir/texts_medium $manifests_dir/texts_large > data/lm/text
  fi

  (echo '<eps> 0'; echo '!SIL 1'; echo '<SPOKEN_NOISE> 2'; echo '<UNK> 3';) \
    > data/lm/words.txt

  cat data/lm/text | sed 's/ /\n/g' | sort -u | sed '/^$/d' \
     | awk '{print $1" "NR+3}' >> data/lm/words.txt

  num_lines=$(< data/lm/words.txt wc -l)
  (echo "#0 $num_lines"; echo "<s> $(($num_lines + 1))"; echo "</s> $(($num_lines + 2))";) \
    >> data/lm/words.txt

  # Train LM on transcripts
  if [ ! -f data/lm/3-gram.unpruned.arpa ]; then
    python3 ./shared/make_kn_lm.py \
      -ngram-order 3 \
      -text data/lm/text \
      -lm data/lm/3-gram.unpruned.arpa
  fi

  # We assume you have install kaldilm, if not, please install
  # it using: pip install kaldilm
  if [ ! -f data/lm/G_3_gram_char.fst.txt ]; then
    # It is used in building HLG
    python3 -m kaldilm \
      --read-symbol-table=data/lm/words.txt \
      --disambig-symbol='#0' \
      --max-order=3 \
      data/lm/3-gram.unpruned.arpa > data/lm/G_3_gram.fst.txt
  fi
fi

