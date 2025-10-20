# mam-ai

MAM-AI is a smart search application developed for nurses and midwives in Zanzibar. This repository
is an MVP for this, as submitted to the [Gemma3n Kaggle challenge](https://www.kaggle.com/competitions/google-gemma-3n-hackathon).

There are three main folders: `rag`, `app`, and `finetune`. `rag` is used for document preprocessing. `app`
contains the actual app. `finetune` is the Gemma3n finetune which we sadly did not manage to deploy
into the Android app (yet).

## Install instructions

Under the GitHub releases tab there is an apk to install :) It may not work on an emulator (according
to the [Google AI Edge RAG](ai.google.dev/edge/mediapipe/solutions/genai/rag/android) documentation)
since the underlying inference library needs real hardware.

You can also build it yourself with `flutter build apk` in the `app/` directory.

## Reproduction instructions

This is a rough sketch of how you could reproduce what we created in this project.

**Prepare RAG docs:**
   1. Curate documents you want to include (or use the Google Drive link from the writeup)
   2. Run [MMORE](https://github.com/swiss-ai/mmore) over these documents to extract their text
   3. Chunk the documents using the scripts in `rag/`
   4. Copy the chunks to the `mamai_trim.txt` in the `assets` folder of the Android app and uncomment the `memorizeChunks()` call
   5. Run the app and wait for it to incorporate the chunks into the sqlite db
   6. Re-comment the `memorizeChunks`
   7. Use `adb` to pull the `embeddings.sqlite` for redistribution

**How we developed the app:**
- Flutter frontend with regular Flutter <-> Android FFI/bridging
  - Built this out to meet our needs
- Adapted the [Google AI Edge RAG](ai.google.dev/edge/mediapipe/solutions/genai/rag/android) for the Android backend which runs the LLM

**Serving the remote files to the users:**
- Start an nginx server with a self-signed cert and the files (see below) in `/var/www/html/`

**Finetuning (not included in app):**

- [Finetuning Dataset](https://drive.google.com/drive/folders/1vdheVGdrOTXwekaIrSkve7JF28Tpq1Xf?usp=sharing)
- [Finetuned Model](https://huggingface.co/fiifidawson/mam-ai-gemma-3n-medical-finetuned)
 - Set Up a Python 3.10 Virtual Environment:
   - `python3.10 -m venv .venv`
   - Windows: `.venv\Scripts\activate`
     Linux: `source .venv/bin/activate`
 - Install core dependencies
   - `pip install -r requirements.txt`
 - Run the Training Script
   - `python train.py` 

## Remote resources 

> **Note: because of the requirements to accept the Gemma3n license before using it, we do not
provide the model files in this repo.** Hence, we host everything on a temporary VPS which will only
remain up during judging. If you are uncomfortable with this, you can simply replace the link with
your own endpoint. 

We host copies of various models on a temporary VPS. The app fetches these the first time it
launches. This is just done for simplicity's sake.

They are as follows:
- `Gecko_1024_quant.tflite`: embedding model from [litert-community/Gecko-110m-en](https://huggingface.co/litert-community/Gecko-110m-en)
- `sentencepiece.model`: tokenizer from [litert-community/Gecko-110m-en](https://huggingface.co/litert-community/Gecko-110m-en)
- `gemma-3n-E4B-it-int4.task`: Gemma3n E4B
- `embeddings.sqlite`: pre-computed document embeddings
