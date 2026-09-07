public with sharing class ChangeLogBulkReviewExtension {
    public List<Id> selectedIds { get; private set; }
    public String actionName { get; private set; }
    public ChangeLogReviewController.ReviewResult result { get; private set; }
    public String errorMessage { get; private set; }

    public ChangeLogBulkReviewExtension(ApexPages.StandardSetController controller) {
        selectedIds = new List<Id>();
        for (SObject row : controller.getSelected()) selectedIds.add((Id)row.get('Id'));
        actionName = ApexPages.currentPage().getParameters().get('action');
        if (String.isBlank(actionName)) {
            String pageName = ApexPages.currentPage().getUrl().toLowerCase();
            actionName = pageName.contains('unauthorise') ? ChangeLogReviewController.UNAUTHORISE
                : pageName.contains('withoutreview') ? ChangeLogReviewController.CLOSE_WITHOUT_REVIEW
                : ChangeLogReviewController.AUTHORISE;
        }
    }

    public PageReference apply() {
        try { result = ChangeLogReviewController.applyAction(selectedIds, actionName); }
        catch (Exception error) { errorMessage = error.getMessage(); }
        return null;
    }

    public PageReference cancel() {
        return new PageReference('/lightning/o/Change_Log__c/list');
    }
}