# Improvements:
* When using CI_PIPELINE, boshes.yml and settings.yml are now using boshes.${CI_PIPELINE}.yml and settings.${CI_PIPELINE}.yml to seperate them in cases of different boshes and vault. If you're using this feature please move your boshes and settings appropriately.
