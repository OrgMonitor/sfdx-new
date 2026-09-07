import { LightningElement, api } from 'lwc';

export default class WizardNavigation extends LightningElement {
    @api currentStepIndex = 0;
    @api totalSteps = 5;
    @api nextLabel = 'Next';
    @api isLoading = false;

    get isFirstStep() {
        return this.currentStepIndex === 0;
    }

    get isLoadingStr() {
        return this.isLoading ? 'true' : 'false';
    }

    get nextAriaLabel() {
        return this.isLoading ? 'Saving, please wait…' : this.nextLabel;
    }

    handleBack() {
        this.dispatchEvent(new CustomEvent('back'));
    }

    handleNext() {
        this.dispatchEvent(new CustomEvent('next'));
    }
}