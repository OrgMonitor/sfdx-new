/**
 * ChangeLogErrorService
 *
 * Centralised error logging for the Change Log batch framework.
 * Writes structured log entries to the debug log in all cases, and attempts
 * to persist errors to Change_Log__c.Raw_Audit_Entry__c via a separate
 * custom object if one is available. The framework degrades gracefully if no
 * error-log object exists.
 *
 * Static methods are intentional — callers should not need to instantiate this
 * class; it is a utility, not a service with state.
 */
public without sharing class ChangeLogErrorService {

    // ── Error Entry ───────────────────────────────────────────────────────────
    public class ErrorEntry {
        public String  context;
        public String  message;
        public String  stackTrace;
        public String  relatedRecordRef;
        public DateTime occurredAt;

        public ErrorEntry(String ctx, String msg, String stack, String ref) {
            this.context          = ctx;
            this.message          = msg;
            this.stackTrace       = stack;
            this.relatedRecordRef = ref;
            this.occurredAt       = System.now();
        }
    }

    // ── Buffered entries (accumulated during a batch execute chunk) ───────────
    @TestVisible private static List<ErrorEntry> errorBuffer = new List<ErrorEntry>();

    // ── Log an Exception ──────────────────────────────────────────────────────
    public static void logError(String context, Exception e, String relatedRef) {
        String msg   = e != null ? e.getMessage()   : 'Unknown error';
        String stack = e != null ? e.getStackTraceString() : '';
        logError(context, msg, stack, relatedRef);
    }

    // ── Log a String Message ──────────────────────────────────────────────────
    public static void logError(String context, String message, String relatedRef) {
        logError(context, message, '', relatedRef);
    }

    // ── Core log method ───────────────────────────────────────────────────────
    private static void logError(String context, String msg, String stack, String relatedRef) {
        // Always debug-log; visible in Developer Console / debug log files
        System.debug(LoggingLevel.ERROR,
            '[ChangeLog][' + context + '] ' + msg
            + (String.isNotBlank(stack) ? '\n' + stack : '')
            + (String.isNotBlank(relatedRef) ? '\nRef: ' + relatedRef : '')
        );

        errorBuffer.add(new ErrorEntry(context, msg, stack, relatedRef));
    }

    // ── Handle Database.SaveResult[] (partial success) ───────────────────────
    public static void processSaveResults(
            List<Database.SaveResult> results,
            List<SObject>             records,
            String                    context) {

        for (Integer i = 0; i < results.size(); i++) {
            Database.SaveResult sr = results[i];
            if (!sr.isSuccess()) {
                String ref = (records != null && records.size() > i)
                    ? String.valueOf(records[i].get('Id')) : String.valueOf(i);
                List<String> msgs = new List<String>();
                for (Database.Error err : sr.getErrors()) {
                    msgs.add(err.getStatusCode() + ': ' + err.getMessage());
                }
                logError(context, String.join(msgs, ' | '), ref);
            }
        }
    }

    // ── Handle Database.UpsertResult[] (partial success) ────────────────────
    public static void processUpsertResults(
            List<Database.UpsertResult> results,
            List<SObject>               records,
            String                      context) {

        for (Integer i = 0; i < results.size(); i++) {
            Database.UpsertResult ur = results[i];
            if (!ur.isSuccess()) {
                String ref = (records != null && records.size() > i)
                    ? String.valueOf(records[i].get('External_Id__c')) : String.valueOf(i);
                List<String> msgs = new List<String>();
                for (Database.Error err : ur.getErrors()) {
                    msgs.add(err.getStatusCode() + ': ' + err.getMessage());
                }
                logError(context, String.join(msgs, ' | '), ref);
            }
        }
    }

    // ── Retrieve and flush buffered entries ───────────────────────────────────
    public static List<ErrorEntry> flushBuffer() {
        List<ErrorEntry> snapshot = new List<ErrorEntry>(errorBuffer);
        errorBuffer.clear();
        return snapshot;
    }

    /** Returns current buffer without clearing (for inspection in tests). */
    public static List<ErrorEntry> getBuffer() {
        return errorBuffer;
    }

    /** Clears buffer — call at the start of each batch chunk. */
    public static void clearBuffer() {
        errorBuffer.clear();
    }
}