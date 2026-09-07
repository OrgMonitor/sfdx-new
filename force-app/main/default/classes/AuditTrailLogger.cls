/**
 * AuditTrailLogger
 * Centralized exception logging utility for the
 * Audit Trail Non-Compliance Monitor package.
 */
public class AuditTrailLogger {

    /**
     * Logs an exception immediately using its own DML context
     * (not rolled back if the calling transaction fails).
     */
    public static void logException(
        Exception e,
        String className,
        String methodName,
        String context
    ) {
        logException(e, className, methodName, context, null, 'High');
    }

    public static void logException(
        Exception e,
        String className,
        String methodName,
        String context,
        Id relatedRecordId,
        String severity
    ) {
        Exception_Log__c log = new Exception_Log__c(
            Apex_Class_Name__c   = className,
            Method_Name__c       = methodName,
            Exception_Type__c    = e.getTypeName(),
            Exception_Message__c = e.getMessage(),
            Stack_Trace__c       = e.getStackTraceString(),
            Line_Number__c       = e.getLineNumber(),
            Severity__c          = severity,
            Context__c           = context,
            Related_Record_Id__c = relatedRecordId,
            Occurred_At__c       = Datetime.now(),
            Resolved__c          = false,
            Notified__c          = false
        );

        try {
            // allOrNone=false so logging failure never throws further
            Database.insert(log, false);
        } catch (Exception loggingFailure) {
            // Last resort — if even logging fails, write to debug log
            System.debug(LoggingLevel.ERROR,
                'AuditTrailLogger failed to insert Exception_Log__c: '
                + loggingFailure.getMessage());
        }
    }
}