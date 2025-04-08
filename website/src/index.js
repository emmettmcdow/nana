const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const printSentences = (id, sentences, speed = 50) => {
  let index = 0;
  let element = document.getElementById(id);
  let sentence = sentences.shift();
  let forwards = true;

  let timer = setInterval(async function () {
    element.innerHTML = sentence.slice(0, index);

    if (forwards) {
      if (++index === sentence.length) {
        await sleep(3000);
        forwards = false;
      }
    } else {
      if (--index === 0) {
        clearInterval(timer);
        printSentences("tw", [...sentences, sentence]);
      }
    }
  }, speed);
};

printSentences("tw", [
  "your brain's search engine",
  "forget everything you know about notes, remember everything else",
  "the notes app steve jobs would have made",
  "the notes app so simple a chimp could use it",
]);
