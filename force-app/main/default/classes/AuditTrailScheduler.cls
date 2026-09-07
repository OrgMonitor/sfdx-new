/**
 * AuditTrailScheduler
 *
 * Schedulable wrapper that launches AuditTrailBatch.
 * Schedule via Developer Console / Anonymous Apex:
 *
 *   System.schedule(
 *       'Audit Trail Batch - Nightly',
 *       '0 0 1 * * ?',            // 01:00 AM every day
 *       new AuditTrailScheduler()
 *   );
 *
 * Or via the Scheduled Apex UI in Setup → Apex Classes → Schedule Apex.
 */
public class AuditTrailScheduler implements Schedulable {

    public void execute(SchedulableContext sc) {
        AuditTrailBatch batch = new AuditTrailBatch();
        Database.executeBatch(batch, AuditTrailConstants.BATCH_SIZE);
    }
}