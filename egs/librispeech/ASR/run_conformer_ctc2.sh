WORLD_SIZE=8
export CUDA_VISIBLE_DEVICES="0,1,2,3,4,5,6,7"
./conformer_ctc2/train.py \
--manifest-dir data/fbank \
--exp-dir conformer_ctc2/exp \
--full-libri 1 \
--spec-aug-time-warp-factor 80 \
--max-duration 1200 \
--world-size ${WORLD_SIZE} \
--start-epoch 1 \
--num-epochs 30 \
--att-rate 0.0 \
--num-encoder-layers 16 \
--num-decoder-layers 0
