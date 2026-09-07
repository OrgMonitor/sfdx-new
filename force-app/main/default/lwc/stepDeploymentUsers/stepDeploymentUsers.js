import { LightningElement, api, track } from 'lwc';

export default class StepDeploymentUsers extends LightningElement {
    @api selectedUsers = [];
    @track isTooltipOpen = false;

    toggleTooltip() {
        this.isTooltipOpen = !this.isTooltipOpen;
    }

    handleSelectionChange(event) {
        this.dispatchEvent(new CustomEvent('selectionchange', {
            detail: { selectedUsers: event.detail.selectedItems },
            bubbles: false,
        }));
    }
}