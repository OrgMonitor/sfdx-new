public with sharing class ChangeLogEmailPageController {

    public List<Change_Log__c> changeLogs { get; private set; }
    public String justificationText { get; private set; }
    public Integer remainingCount { get; private set; }
    public String listViewUrl { get; private set; }

    public ChangeLogEmailPageController() {
        String idsParam = ApexPages.currentPage().getParameters().get('recordIds');
        justificationText = ApexPages.currentPage().getParameters().get('justification');

        String remainingParam = ApexPages.currentPage().getParameters().get('remainingCount');
        remainingCount = String.isNotBlank(remainingParam) ? Integer.valueOf(remainingParam) : 0;
        System.debug('remainingCount::::' + remainingCount);
        //listViewUrl = ApexPages.currentPage().getParameters().get('listViewUrl');
        String rawListViewUrl = ApexPages.currentPage().getParameters().get('listViewUrl');
        listViewUrl = String.isNotBlank(rawListViewUrl) ? EncodingUtil.urlDecode(rawListViewUrl, 'UTF-8') : '';
        System.debug('Controller received listViewUrl: ' + listViewUrl);
 
		System.debug('listViewUrl::' + listViewUrl);
        changeLogs = new List<Change_Log__c>();

        if (String.isNotBlank(idsParam)) {
            List<Id> ids = new List<Id>();
            for (String s : idsParam.split(',')) {
                if (String.isNotBlank(s)) {
                    ids.add((Id) s);
                }
            }

            changeLogs = [
                SELECT Id, Name, External_Id__c, Section__c, Action__c,
                       Log_Created_Date__c, Changed_By_User__c, Changed_By_User__r.Name,
                       IP_Address__c, User_Location_City__c,
                       User_Location_State__c, User_Location_Country__c,
                       Non_Compliant__c, Email_Sent__c, Non_Compliant_Reason__c ,
                       Related_Case__c, Related_Case__r.CaseNumber, Severity__c
                FROM Change_Log__c
                WHERE Id IN :ids
            ];
        }
    }
}