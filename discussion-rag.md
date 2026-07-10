# Discussion initiale : choix d'Ollama et du RAG

> Conversation de cadrage initiale ayant abouti à ce projet. Conservée pour traçabilité.

## Résumé des décisions

- **Moteur LLM local** : Ollama (wrapper llama.cpp, API REST :11434, gestion modèles).
- **Besoin** : indexer des documents et les interroger en langage naturel → **RAG**
  (Retrieval-Augmented Generation : on récupère les passages pertinents par
  similarité sémantique, puis on les injecte dans le prompt du LLM).
- **Approche retenue** : clé-en-main avec **Open WebUI** (RAG intégré, multi-utilisateur).
- **Documents** : PDF natifs, PDF scannés (→ OCR), pages web, notes/Markdown.
- **Usage** : multi-utilisateur / partagé (réseau local).
- **Langue** : français → embedding `bge-m3`, génératif `qwen2.5:7b`.

## Points techniques clés retenus de la discussion

- La qualité d'un RAG tient à ~80 % au **retrieval**, pas au LLM.
- Leviers décisifs : modèle d'**embedding** adapté au français (`bge-m3`),
  stratégie de **chunking** (taille/overlap/sémantique), et **reranking**.
- Pour du contenu FR, éviter un embedding anglophone par défaut.
