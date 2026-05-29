import { app } from "./app";

// Worker entrypoint. fetch only for now; email + scheduled handlers land
// with the email-in and budget-push phases.
export default {
  fetch: app.fetch,
};
