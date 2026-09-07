trigger DeploymentWindowApprovalCapture on Deployment_Window__c (before update) {
    for (Deployment_Window__c windowRecord : Trigger.new) {
        Deployment_Window__c previous = Trigger.oldMap.get(windowRecord.Id);
        if (previous.Status__c != 'Active'
                && windowRecord.Status__c == 'Active'
                && windowRecord.Enable_Approval_Process__c == true
                && windowRecord.Approved_By__c == null) {
            windowRecord.Approved_By__c = UserInfo.getUserId();
        }
    }
}