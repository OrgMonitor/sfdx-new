/**
 * ChangeLogMdtDeployCallback
 * Metadata.DeployCallback implementation invoked after the async CMT deployment
 * that updates Last_Run_Timestamp__c on Change_Log_Config__mdt.Default.
 * Any deployment errors are logged via ChangeLogErrorService.
 */
public class ChangeLogMdtDeployCallback implements Metadata.DeployCallback {

    public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext context) {
        if (result == null) return;
        if (!result.done || !result.success) {
            String msg = 'CMT timestamp update failed.'
                + (result.errorMessage != null ? ' | ' + result.errorMessage : '');
            ChangeLogErrorService.logError('ChangeLogMdtDeployCallback', msg, null);
        }
    }
}