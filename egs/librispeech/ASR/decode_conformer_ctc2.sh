for method in ctc-greedy-search ctc-decoding 1best nbest-oracle; do
  python3 ./conformer_ctc2/decode.py \
  --exp-dir conformer_ctc2/241025_conformer_ctc2 \
  --num-encoder-layers 18 --num-decoder-layers 0 \
  --use-averaged-model True --epoch 30 --avg 8 --max-duration 200 --method $method
done

#for method in nbest nbest-rescoring whole-lattice-rescoring attention-decoder ; do
#  python3 ./conformer_ctc2/decode.py \
#  --exp-dir conformer_ctc2/241025_conformer_ctc2 \
#  --use-averaged-model True --epoch 30 --avg 8 --max-duration 20 --method $method
#done
