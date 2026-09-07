/**
 * AuditTrailMdtDeployCallback
 * Metadata.DeployCallback implementation invoked after the async CMT deployment
 * that updates Last_Run_Timestamp__c on Audit_Trail_Config__mdt.Default.
 * Any deployment errors are logged via AuditTrailErrorService.
 */
public class AuditTrailMdtDeployCallback implements Metadata.DeployCallback {

    public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext context) {
        if (result == null) return;
        if (!result.done || !result.success) {
            String msg = 'CMT timestamp update failed.'
                + (result.errorMessage != null ? ' | ' + result.errorMessage : '');
            AuditTrailErrorService.logError('AuditTrailMdtDeployCallback', msg, null);
        }
    }
}