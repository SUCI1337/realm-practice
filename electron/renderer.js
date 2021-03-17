const { RealmUtils } = require('./realmUtils');

function logOnHTML(message) {
  let date = new Date();

  let container = document.getElementById('log');

  if (!container) {
    container = document.createElement('div');
    container.setAttribute('id', 'log');
    document.body.appendChild(container);
  }
  let paragraph = document.createElement('p');

  paragraph.innerHTML = `[${date.toISOString()}] - ${message}`;

  container.appendChild(paragraph);
}

async function run() {
  try {
    logOnHTML(`Opened LOCAL realm`);

    let realmUtils = await new RealmUtils(null, true);

    if (realmUtils.realm) {
      let objects = realmUtils.realm.objects('TestData');

      logOnHTML(`Got ${objects.length} objects`);

      function listener(objects, changes) {
        logOnHTML(
          `Received ${changes.deletions.length} deleted, ${changes.insertions.length} inserted, ${changes.newModifications.length} updates`
        );
      }

      objects.addListener(listener);
    }
  } catch (error) {
    console.error(error);
  }
}

run().catch((err) => {
  console.error('Failed to open realm:', err);
});