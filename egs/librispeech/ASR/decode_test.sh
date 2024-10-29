for method in 1best; do
  python3 ./conformer_ctc2/decode.py \
  --exp-dir conformer_ctc2/241026_conformer_ctc2_aed \
  --num-encoder-layers 12 --num-decoder-layers 6 \
  --use-averaged-model True --epoch 30 --avg 8 --max-duration 200 --method $method
done
