# WeSpeaker ResNet34-LM

`wespeaker_int8.mlmodelc` is the unchanged 8-bit-palettized Core ML conversion by
[Fluid Inference](https://huggingface.co/FluidInference/speaker-diarization-coreml/tree/7eab74f3463c736418d0eb10296261ae581146c9/wespeaker_int8.mlmodelc).
It is derived from [WeSpeaker](https://github.com/wenet-e2e/wespeaker)'s VoxCeleb ResNet34-LM
via [pyannote](https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM).
Fluid Inference modified the original by fusing the feature frontend, fixing input shapes,
converting to Core ML, and palettizing the weights. See their
[upstream attribution and provenance](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/7eab74f3463c736418d0eb10296261ae581146c9/NOTICE.md).
The converted model is distributed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
