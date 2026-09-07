trigger ChangeLogLifecycle on Change_Log__c (before insert, before update) {
    ChangeLogLifecycleHandler.beforeSave(Trigger.new, Trigger.isInsert ? null : Trigger.oldMap);
}