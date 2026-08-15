#pragma once

#include "Commandlets/Commandlet.h"
#include "PalSkillDPSGenerateUICommandlet.generated.h"

UCLASS()
class UPalSkillDPSGenerateUICommandlet : public UCommandlet
{
    GENERATED_BODY()

public:
    UPalSkillDPSGenerateUICommandlet();
    virtual int32 Main(const FString& Params) override;
};
