/**
 * AuditTrailComplianceScheduler
 *
 * Schedulable entry-point for the hourly compliance run.
 * Governance Setup Wizard schedules this class to run every hour via:
 *   GovernanceSetupController.scheduleCompliance()
 *
 * To manually schedule (Anonymous Apex):
 *   System.schedule('AuditTrailCompliance_Hourly', '0 0 * * * ?', new AuditTrailComplianceScheduler());
 */
public class AuditTrailComplianceScheduler implements Schedulable {

    public void execute(SchedulableContext sc) {
        AuditTrailBatch batch = new AuditTrailBatch();
        Database.executeBatch(batch, AuditTrailConstants.BATCH_SIZE);
    }
}