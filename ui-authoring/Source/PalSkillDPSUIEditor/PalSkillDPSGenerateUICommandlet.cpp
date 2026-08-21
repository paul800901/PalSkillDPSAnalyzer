#include "PalSkillDPSGenerateUICommandlet.h"

#include "AssetRegistry/AssetRegistryModule.h"
#include "Blueprint/WidgetTree.h"
#include "CommonActivatableWidget.h"
#include "Components/Border.h"
#include "Components/Button.h"
#include "Components/CanvasPanel.h"
#include "Components/CanvasPanelSlot.h"
#include "Components/HorizontalBox.h"
#include "Components/HorizontalBoxSlot.h"
#include "Components/Overlay.h"
#include "Components/ScrollBox.h"
#include "Components/SizeBox.h"
#include "Components/Spacer.h"
#include "Components/TextBlock.h"
#include "Components/VerticalBox.h"
#include "Components/VerticalBoxSlot.h"
#include "Components/WidgetSwitcher.h"
#include "EdGraph/EdGraph.h"
#include "EdGraph/EdGraphPin.h"
#include "EdGraphSchema_K2.h"
#include "EdGraphSchema_K2_Actions.h"
#include "Engine/Blueprint.h"
#include "Engine/BlueprintGeneratedClass.h"
#include "GameFramework/Actor.h"
#include "K2Node.h"
#include "K2Node_CallFunction.h"
#include "K2Node_ComponentBoundEvent.h"
#include "Kismet/KismetSystemLibrary.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "Misc/PackageName.h"
#include "ObjectTools.h"
#include "UObject/SavePackage.h"
#include "UObject/UnrealType.h"
#include "Blueprint/UserWidget.h"
#include "WidgetBlueprint.h"
#include "WidgetBlueprintFactory.h"

namespace
{
constexpr TCHAR AssetPackageName[] = TEXT("/Game/Mods/PalSkillDPSAnalyzerSP/WBP_PalSkillDPSSettings");
constexpr TCHAR AssetName[] = TEXT("WBP_PalSkillDPSSettings");
constexpr TCHAR BootstrapPackageName[] = TEXT("/Game/Mods/PalSkillDPSAnalyzerSP/ModActor");
constexpr TCHAR BootstrapAssetName[] = TEXT("ModActor");
constexpr TCHAR BootstrapWidgetClassProperty[] = TEXT("SettingsWidgetClass");

const FLinearColor PanelBackground(0.018f, 0.071f, 0.094f, 0.97f);
const FLinearColor SectionBackground(0.025f, 0.115f, 0.145f, 0.94f);
const FLinearColor AccentBlue(0.00f, 0.78f, 0.98f, 1.0f);
const FLinearColor PrimaryText(0.88f, 0.97f, 1.0f, 1.0f);
const FLinearColor SecondaryText(0.47f, 0.72f, 0.79f, 1.0f);

UTextBlock* MakeText(UWidgetTree* Tree, FName Name, const FString& Value, int32 Size, const FLinearColor& Color)
{
    UTextBlock* Text = Tree->ConstructWidget<UTextBlock>(UTextBlock::StaticClass(), Name);
    Text->SetText(FText::FromString(Value));
    Text->SetColorAndOpacity(FSlateColor(Color));
    Text->Font.Size = Size;
    return Text;
}

UButton* MakeButton(
    UWidgetTree* Tree,
    FName Name,
    const FString& Label,
    float MinWidth = 74.0f,
    FName LabelName = NAME_None)
{
    UButton* Button = Tree->ConstructWidget<UButton>(UButton::StaticClass(), Name);
    Button->SetIsEnabled(true);
    Button->SetBackgroundColor(FLinearColor(0.055f, 0.25f, 0.31f, 1.0f));
    USizeBox* Size = Tree->ConstructWidget<USizeBox>();
    Size->SetMinDesiredWidth(MinWidth);
    Size->SetMinDesiredHeight(38.0f);
    UTextBlock* Text = MakeText(Tree, LabelName, Label, 16, PrimaryText);
    Text->bIsVariable = !LabelName.IsNone();
    Text->SetJustification(ETextJustify::Center);
    Size->AddChild(Text);
    Button->AddChild(Size);
    return Button;
}

void SetHorizontalPadding(UWidget* Widget, float Left, float Top, float Right, float Bottom)
{
    if (UHorizontalBoxSlot* Slot = Cast<UHorizontalBoxSlot>(Widget->Slot))
    {
        Slot->SetPadding(FMargin(Left, Top, Right, Bottom));
        Slot->SetVerticalAlignment(VAlign_Center);
    }
}

void SetVerticalPadding(UWidget* Widget, float Left, float Top, float Right, float Bottom)
{
    if (UVerticalBoxSlot* Slot = Cast<UVerticalBoxSlot>(Widget->Slot))
    {
        Slot->SetPadding(FMargin(Left, Top, Right, Bottom));
    }
}

void AddSettingRow(
    UWidgetTree* Tree,
    UVerticalBox* Parent,
    const FString& Key,
    const FString& Label,
    const FString& DefaultValue)
{
    UBorder* RowBorder = Tree->ConstructWidget<UBorder>();
    RowBorder->SetBrushColor(SectionBackground);
    RowBorder->SetPadding(FMargin(14.0f, 8.0f));
    Parent->AddChild(RowBorder);
    SetVerticalPadding(RowBorder, 0.0f, 2.0f, 0.0f, 2.0f);

    UHorizontalBox* Row = Tree->ConstructWidget<UHorizontalBox>();
    RowBorder->AddChild(Row);

    USizeBox* LabelSize = Tree->ConstructWidget<USizeBox>();
    LabelSize->SetWidthOverride(260.0f);
    LabelSize->AddChild(MakeText(Tree, NAME_None, Label, 16, PrimaryText));
    Row->AddChild(LabelSize);
    SetHorizontalPadding(LabelSize, 0.0f, 0.0f, 12.0f, 0.0f);

    const FString PrevName = FString::Printf(TEXT("PSDPS_%s_Prev"), *Key);
    UButton* Prev = MakeButton(Tree, *PrevName, TEXT("<"), 48.0f);
    Prev->bIsVariable = true;
    Row->AddChild(Prev);

    USizeBox* ValueSize = Tree->ConstructWidget<USizeBox>();
    ValueSize->SetWidthOverride(250.0f);
    UTextBlock* Value = MakeText(
        Tree,
        *FString::Printf(TEXT("PSDPS_%s_Value"), *Key),
        DefaultValue,
        16,
        AccentBlue);
    Value->bIsVariable = true;
    Value->SetJustification(ETextJustify::Center);
    ValueSize->AddChild(Value);
    Row->AddChild(ValueSize);

    const FString NextName = FString::Printf(TEXT("PSDPS_%s_Next"), *Key);
    UButton* Next = MakeButton(Tree, *NextName, TEXT(">"), 48.0f);
    Next->bIsVariable = true;
    Row->AddChild(Next);
}

bool AddConsoleCommandBinding(UWidgetBlueprint* Blueprint, FName ButtonName, const FString& Command, int32 NodeY)
{
    if (Blueprint == nullptr || Blueprint->SkeletonGeneratedClass == nullptr)
    {
        return false;
    }

    FObjectProperty* ComponentProperty = FindFProperty<FObjectProperty>(Blueprint->SkeletonGeneratedClass, ButtonName);
    FMulticastDelegateProperty* DelegateProperty = FindFProperty<FMulticastDelegateProperty>(UButton::StaticClass(), TEXT("OnClicked"));
    UEdGraph* Graph = Blueprint->GetLastEditedUberGraph();
    UFunction* ExecuteCommand = UKismetSystemLibrary::StaticClass()->FindFunctionByName(
        GET_FUNCTION_NAME_CHECKED(UKismetSystemLibrary, ExecuteConsoleCommand));
    if (ComponentProperty == nullptr || DelegateProperty == nullptr || Graph == nullptr || ExecuteCommand == nullptr)
    {
        UE_LOG(LogTemp, Error, TEXT("Cannot bind %s (property=%p delegate=%p graph=%p function=%p)"),
            *ButtonName.ToString(), ComponentProperty, DelegateProperty, Graph, ExecuteCommand);
        return false;
    }

    UK2Node_ComponentBoundEvent* EventNode = FEdGraphSchemaAction_K2NewNode::SpawnNode<UK2Node_ComponentBoundEvent>(
        Graph,
        FVector2D(0.0f, static_cast<float>(NodeY)),
        EK2NewNodeFlags::None,
        [ComponentProperty, DelegateProperty](UK2Node_ComponentBoundEvent* Node)
        {
            Node->InitializeComponentBoundEventParams(ComponentProperty, DelegateProperty);
        });

    UK2Node_CallFunction* CallNode = FEdGraphSchemaAction_K2NewNode::SpawnNode<UK2Node_CallFunction>(
        Graph,
        FVector2D(380.0f, static_cast<float>(NodeY)),
        EK2NewNodeFlags::None,
        [ExecuteCommand](UK2Node_CallFunction* Node)
        {
            Node->SetFromFunction(ExecuteCommand);
        });

    if (EventNode == nullptr || CallNode == nullptr)
    {
        return false;
    }

    UEdGraphPin* EventThen = EventNode->FindPin(UEdGraphSchema_K2::PN_Then);
    UEdGraphPin* CallExecute = CallNode->FindPin(UEdGraphSchema_K2::PN_Execute);
    UEdGraphPin* CommandPin = CallNode->FindPin(TEXT("Command"));
    const UEdGraphSchema_K2* Schema = GetDefault<UEdGraphSchema_K2>();
    if (EventThen == nullptr || CallExecute == nullptr || CommandPin == nullptr
        || !Schema->TryCreateConnection(EventThen, CallExecute))
    {
        UE_LOG(LogTemp, Error, TEXT("Cannot connect command graph for %s"), *ButtonName.ToString());
        return false;
    }
    CommandPin->DefaultValue = Command;
    return true;
}

void AddSectionTitle(UWidgetTree* Tree, UVerticalBox* Parent, const FString& Text)
{
    UTextBlock* Title = MakeText(Tree, NAME_None, Text, 15, AccentBlue);
    Parent->AddChild(Title);
    SetVerticalPadding(Title, 4.0f, 12.0f, 0.0f, 6.0f);
}
}

UPalSkillDPSGenerateUICommandlet::UPalSkillDPSGenerateUICommandlet()
{
    IsClient = false;
    IsEditor = true;
    IsServer = false;
    LogToConsole = true;
    ShowErrorCount = true;
}

int32 UPalSkillDPSGenerateUICommandlet::Main(const FString& Params)
{
    UE_LOG(LogTemp, Display, TEXT("Generating Pal Skill DPS native CommonUI asset"));

    if (UPackage* ExistingPackage = FindPackage(nullptr, AssetPackageName))
    {
        ExistingPackage->FullyLoad();
    }
    if (UObject* Existing = StaticFindObject(UObject::StaticClass(), nullptr, AssetPackageName))
    {
        ObjectTools::DeleteSingleObject(Existing, false);
    }
    if (UPackage* ExistingBootstrapPackage = FindPackage(nullptr, BootstrapPackageName))
    {
        ExistingBootstrapPackage->FullyLoad();
    }
    if (UObject* ExistingBootstrap = StaticFindObject(UObject::StaticClass(), nullptr, BootstrapPackageName))
    {
        ObjectTools::DeleteSingleObject(ExistingBootstrap, false);
    }

    UPackage* Package = CreatePackage(AssetPackageName);
    UWidgetBlueprintFactory* Factory = NewObject<UWidgetBlueprintFactory>();
    Factory->ParentClass = UCommonActivatableWidget::StaticClass();
    UWidgetBlueprint* Blueprint = Cast<UWidgetBlueprint>(Factory->FactoryCreateNew(
        UWidgetBlueprint::StaticClass(),
        Package,
        AssetName,
        RF_Public | RF_Standalone,
        nullptr,
        GWarn));
    if (Blueprint == nullptr || Blueprint->WidgetTree == nullptr)
    {
        UE_LOG(LogTemp, Error, TEXT("Failed to create Widget Blueprint"));
        return 1;
    }

    UWidgetTree* Tree = Blueprint->WidgetTree;
    UCanvasPanel* Root = Tree->ConstructWidget<UCanvasPanel>(UCanvasPanel::StaticClass(), TEXT("PSDPS_Root"));
    Tree->RootWidget = Root;

    UBorder* Dimmer = Tree->ConstructWidget<UBorder>();
    Dimmer->SetBrushColor(FLinearColor(0.0f, 0.0f, 0.0f, 0.36f));
    Root->AddChild(Dimmer);
    if (UCanvasPanelSlot* Slot = Cast<UCanvasPanelSlot>(Dimmer->Slot))
    {
        Slot->SetAnchors(FAnchors(0.0f, 0.0f, 1.0f, 1.0f));
        Slot->SetOffsets(FMargin(0.0f));
    }

    constexpr float SettingsPanelWidth = 920.0f;
    constexpr float SettingsPanelHeight = 780.0f;
    USizeBox* PanelSize = Tree->ConstructWidget<USizeBox>();
    PanelSize->SetMinDesiredWidth(SettingsPanelWidth);
    PanelSize->SetMinDesiredHeight(SettingsPanelHeight);
    PanelSize->SetWidthOverride(SettingsPanelWidth);
    PanelSize->SetHeightOverride(SettingsPanelHeight);
    Root->AddChild(PanelSize);
    if (UCanvasPanelSlot* Slot = Cast<UCanvasPanelSlot>(PanelSize->Slot))
    {
        Slot->SetAnchors(FAnchors(0.5f, 0.5f));
        Slot->SetAlignment(FVector2D(0.5f, 0.5f));
        Slot->SetPosition(FVector2D::ZeroVector);
        Slot->SetSize(FVector2D(SettingsPanelWidth, SettingsPanelHeight));
    }

    UBorder* Panel = Tree->ConstructWidget<UBorder>();
    Panel->SetBrushColor(PanelBackground);
    Panel->SetPadding(FMargin(18.0f));
    PanelSize->AddChild(Panel);

    UVerticalBox* Main = Tree->ConstructWidget<UVerticalBox>();
    Panel->AddChild(Main);

    UHorizontalBox* Header = Tree->ConstructWidget<UHorizontalBox>();
    Main->AddChild(Header);
    SetVerticalPadding(Header, 0.0f, 0.0f, 0.0f, 10.0f);

    UTextBlock* Title = MakeText(Tree, TEXT("PSDPS_Title"), TEXT("帕魯技能 DPS"), 26, PrimaryText);
    Title->bIsVariable = true;
    Title->SetAutoWrapText(false);
    Header->AddChild(Title);
    if (UHorizontalBoxSlot* Slot = Cast<UHorizontalBoxSlot>(Title->Slot))
    {
        Slot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
        Slot->SetVerticalAlignment(VAlign_Center);
    }
    SetHorizontalPadding(Title, 0.0f, 0.0f, 16.0f, 0.0f);

    UButton* Reset = MakeButton(Tree, TEXT("PSDPS_Reset"), TEXT("重設測試"), 118.0f);
    Reset->bIsVariable = true;
    Header->AddChild(Reset);
    SetHorizontalPadding(Reset, 4.0f, 0.0f, 4.0f, 0.0f);

    UButton* Close = MakeButton(Tree, TEXT("PSDPS_Close"), TEXT("關閉"), 86.0f);
    Close->bIsVariable = true;
    Header->AddChild(Close);
    SetHorizontalPadding(Close, 4.0f, 0.0f, 0.0f, 0.0f);

    UHorizontalBox* Tabs = Tree->ConstructWidget<UHorizontalBox>();
    Main->AddChild(Tabs);
    SetVerticalPadding(Tabs, 0.0f, 0.0f, 0.0f, 10.0f);
    UButton* TabSettings = MakeButton(
        Tree,
        TEXT("PSDPS_TabSettings"),
        TEXT("設定"),
        150.0f,
        TEXT("PSDPS_TabSettingsLabel"));
    TabSettings->bIsVariable = true;
    Tabs->AddChild(TabSettings);
    SetHorizontalPadding(TabSettings, 0.0f, 0.0f, 6.0f, 0.0f);
    UButton* TabGroups = MakeButton(
        Tree,
        TEXT("PSDPS_TabGroups"),
        TEXT("分組百分比"),
        180.0f,
        TEXT("PSDPS_TabGroupsLabel"));
    TabGroups->bIsVariable = true;
    Tabs->AddChild(TabGroups);
    SetHorizontalPadding(TabGroups, 0.0f, 0.0f, 6.0f, 0.0f);
    UButton* TabDetails = MakeButton(
        Tree,
        TEXT("PSDPS_TabDetails"),
        TEXT("本次測試詳情"),
        210.0f,
        TEXT("PSDPS_TabDetailsLabel"));
    TabDetails->bIsVariable = true;
    Tabs->AddChild(TabDetails);

    UWidgetSwitcher* Switcher = Tree->ConstructWidget<UWidgetSwitcher>(UWidgetSwitcher::StaticClass(), TEXT("PSDPS_PageSwitcher"));
    Switcher->bIsVariable = true;
    Main->AddChild(Switcher);
    if (UVerticalBoxSlot* Slot = Cast<UVerticalBoxSlot>(Switcher->Slot))
    {
        Slot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
    }

    UScrollBox* SettingsScroll = Tree->ConstructWidget<UScrollBox>();
    Switcher->AddChild(SettingsScroll);
    UVerticalBox* SettingsPage = Tree->ConstructWidget<UVerticalBox>();
    SettingsScroll->AddChild(SettingsPage);

    AddSectionTitle(Tree, SettingsPage, TEXT("一般"));
    AddSettingRow(Tree, SettingsPage, TEXT("Language"), TEXT("顯示語言"), TEXT("跟隨遊戲"));
    AddSectionTitle(Tree, SettingsPage, TEXT("測量"));
    AddSettingRow(Tree, SettingsPage, TEXT("MeasurementMode"), TEXT("測試分場方式"), TEXT("手動測試區間"));
    AddSettingRow(Tree, SettingsPage, TEXT("TargetScope"), TEXT("測試類型"), TEXT("野外／副本 Boss"));
    AddSettingRow(Tree, SettingsPage, TEXT("IncludePlayerDamage"), TEXT("納入人物／武器傷害"), TEXT("關"));
    AddSectionTitle(Tree, SettingsPage, TEXT("顯示"));
    AddSettingRow(Tree, SettingsPage, TEXT("EnableSkillDPSHUD"), TEXT("顯示技能 DPS 面板"), TEXT("開"));
    AddSettingRow(Tree, SettingsPage, TEXT("HUDAnchor"), TEXT("面板位置"), TEXT("左側安全區"));
    AddSettingRow(Tree, SettingsPage, TEXT("HUDScale"), TEXT("面板縮放"), TEXT("85%"));
    AddSettingRow(Tree, SettingsPage, TEXT("HUDFinalResultSeconds"), TEXT("結算顯示時間"), TEXT("保留"));
    UVerticalBox* GroupsPage = Tree->ConstructWidget<UVerticalBox>();
    Switcher->AddChild(GroupsPage);
    UTextBlock* GroupIntro = MakeText(
        Tree,
        TEXT("PSDPS_GroupIntro"),
        TEXT("完整列出主 HUD 的配招分組、總傷占比與技能組內占比。"),
        15,
        SecondaryText);
    GroupIntro->bIsVariable = true;
    GroupIntro->SetAutoWrapText(true);
    GroupsPage->AddChild(GroupIntro);
    SetVerticalPadding(GroupIntro, 2.0f, 4.0f, 2.0f, 14.0f);

    UBorder* GroupBorder = Tree->ConstructWidget<UBorder>();
    GroupBorder->SetBrushColor(SectionBackground);
    GroupBorder->SetPadding(FMargin(14.0f));
    GroupsPage->AddChild(GroupBorder);
    if (UVerticalBoxSlot* Slot = Cast<UVerticalBoxSlot>(GroupBorder->Slot))
    {
        Slot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
    }
    UScrollBox* GroupScroll = Tree->ConstructWidget<UScrollBox>();
    GroupBorder->AddChild(GroupScroll);
    UTextBlock* GroupRows = MakeText(
        Tree,
        TEXT("PSDPS_GroupRows"),
        TEXT("尚未記錄傷害。關閉 F3 後，讓任一隻帕魯命中 Boss 即可開始。"),
        16,
        PrimaryText);
    GroupRows->bIsVariable = true;
    GroupRows->SetAutoWrapText(true);
    GroupScroll->AddChild(GroupRows);

    UVerticalBox* DetailsPage = Tree->ConstructWidget<UVerticalBox>();
    Switcher->AddChild(DetailsPage);
    UTextBlock* DetailIntro = MakeText(
        Tree,
        TEXT("PSDPS_DetailIntro"),
        TEXT("逐隻保留實際傷害、DPS、施放與 Hit 詳細資料。"),
        15,
        SecondaryText);
    DetailIntro->bIsVariable = true;
    DetailIntro->SetAutoWrapText(true);
    DetailsPage->AddChild(DetailIntro);
    SetVerticalPadding(DetailIntro, 2.0f, 4.0f, 2.0f, 14.0f);

    UBorder* DetailBorder = Tree->ConstructWidget<UBorder>();
    DetailBorder->SetBrushColor(SectionBackground);
    DetailBorder->SetPadding(FMargin(14.0f));
    DetailsPage->AddChild(DetailBorder);
    if (UVerticalBoxSlot* Slot = Cast<UVerticalBoxSlot>(DetailBorder->Slot))
    {
        Slot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
    }
    UScrollBox* DetailScroll = Tree->ConstructWidget<UScrollBox>();
    DetailBorder->AddChild(DetailScroll);
    UTextBlock* DetailRows = MakeText(
        Tree,
        TEXT("PSDPS_DetailRows"),
        TEXT("尚未記錄傷害。關閉 F3 後，讓任一隻帕魯命中 Boss 即可開始。"),
        16,
        PrimaryText);
    DetailRows->bIsVariable = true;
    DetailRows->SetAutoWrapText(true);
    DetailScroll->AddChild(DetailRows);

    UTextBlock* Footer = MakeText(
        Tree,
        TEXT("PSDPS_Footer"),
        TEXT("F2 重設測試　｜　F3 關閉設定　｜　設定會自動儲存"),
        14,
        SecondaryText);
    Footer->bIsVariable = true;
    Main->AddChild(Footer);
    SetVerticalPadding(Footer, 2.0f, 10.0f, 2.0f, 0.0f);

    Switcher->SetActiveWidgetIndex(0);

    FAssetRegistryModule::AssetCreated(Blueprint);
    FKismetEditorUtilities::CompileBlueprint(Blueprint);

    struct FBindingSpec
    {
        FName Button;
        FString Command;
    };
    const TArray<FBindingSpec> Bindings = {
        { TEXT("PSDPS_Close"), TEXT("psdps ui close") },
        { TEXT("PSDPS_Reset"), TEXT("psdps ui reset") },
        { TEXT("PSDPS_TabSettings"), TEXT("psdps ui tab settings") },
        { TEXT("PSDPS_TabGroups"), TEXT("psdps ui tab groups") },
        { TEXT("PSDPS_TabDetails"), TEXT("psdps ui tab details") },
        { TEXT("PSDPS_Language_Prev"), TEXT("psdps ui cycle Language -1") },
        { TEXT("PSDPS_Language_Next"), TEXT("psdps ui cycle Language 1") },
        { TEXT("PSDPS_MeasurementMode_Prev"), TEXT("psdps ui cycle MeasurementMode -1") },
        { TEXT("PSDPS_MeasurementMode_Next"), TEXT("psdps ui cycle MeasurementMode 1") },
        { TEXT("PSDPS_TargetScope_Prev"), TEXT("psdps ui cycle TargetScope -1") },
        { TEXT("PSDPS_TargetScope_Next"), TEXT("psdps ui cycle TargetScope 1") },
        { TEXT("PSDPS_IncludePlayerDamage_Prev"), TEXT("psdps ui cycle IncludePlayerDamage -1") },
        { TEXT("PSDPS_IncludePlayerDamage_Next"), TEXT("psdps ui cycle IncludePlayerDamage 1") },
        { TEXT("PSDPS_EnableSkillDPSHUD_Prev"), TEXT("psdps ui cycle EnableSkillDPSHUD -1") },
        { TEXT("PSDPS_EnableSkillDPSHUD_Next"), TEXT("psdps ui cycle EnableSkillDPSHUD 1") },
        { TEXT("PSDPS_HUDAnchor_Prev"), TEXT("psdps ui cycle HUDAnchor -1") },
        { TEXT("PSDPS_HUDAnchor_Next"), TEXT("psdps ui cycle HUDAnchor 1") },
        { TEXT("PSDPS_HUDScale_Prev"), TEXT("psdps ui cycle HUDScale -1") },
        { TEXT("PSDPS_HUDScale_Next"), TEXT("psdps ui cycle HUDScale 1") },
        { TEXT("PSDPS_HUDFinalResultSeconds_Prev"), TEXT("psdps ui cycle HUDFinalResultSeconds -1") },
        { TEXT("PSDPS_HUDFinalResultSeconds_Next"), TEXT("psdps ui cycle HUDFinalResultSeconds 1") },
    };

    bool AllBound = true;
    int32 NodeY = 0;
    for (const FBindingSpec& Binding : Bindings)
    {
        AllBound = AddConsoleCommandBinding(Blueprint, Binding.Button, Binding.Command, NodeY) && AllBound;
        NodeY += 180;
    }
    if (!AllBound)
    {
        UE_LOG(LogTemp, Error, TEXT("One or more UI command bindings failed"));
        return 2;
    }

    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(Blueprint);
    FKismetEditorUtilities::CompileBlueprint(Blueprint);
    if (Blueprint->Status == BS_Error)
    {
        UE_LOG(LogTemp, Error, TEXT("Generated Widget Blueprint contains compile errors"));
        return 3;
    }

    Package->MarkPackageDirty();
    const FString Filename = FPackageName::LongPackageNameToFilename(AssetPackageName, FPackageName::GetAssetPackageExtension());
    FSavePackageArgs SaveArgs;
    SaveArgs.TopLevelFlags = RF_Public | RF_Standalone;
    SaveArgs.SaveFlags = SAVE_NoError;
    if (!UPackage::SavePackage(Package, Blueprint, *Filename, SaveArgs))
    {
        UE_LOG(LogTemp, Error, TEXT("Failed to save %s"), *Filename);
        return 4;
    }

    UPackage* BootstrapPackage = CreatePackage(BootstrapPackageName);
    UBlueprint* Bootstrap = FKismetEditorUtilities::CreateBlueprint(
        AActor::StaticClass(),
        BootstrapPackage,
        BootstrapAssetName,
        BPTYPE_Normal,
        UBlueprint::StaticClass(),
        UBlueprintGeneratedClass::StaticClass(),
        FName(TEXT("PalSkillDPSGenerateUI")));
    if (Bootstrap == nullptr)
    {
        UE_LOG(LogTemp, Error, TEXT("Failed to create LogicMods bootstrap Blueprint"));
        return 5;
    }

    FEdGraphPinType WidgetClassType;
    WidgetClassType.PinCategory = UEdGraphSchema_K2::PC_Class;
    WidgetClassType.PinSubCategoryObject = UUserWidget::StaticClass();
    if (!FBlueprintEditorUtils::AddMemberVariable(
            Bootstrap,
            BootstrapWidgetClassProperty,
            WidgetClassType))
    {
        UE_LOG(LogTemp, Error, TEXT("Failed to add bootstrap Widget class reference"));
        return 6;
    }

    FAssetRegistryModule::AssetCreated(Bootstrap);
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(Bootstrap);
    FKismetEditorUtilities::CompileBlueprint(Bootstrap);
    if (Bootstrap->Status == BS_Error || Bootstrap->GeneratedClass == nullptr)
    {
        UE_LOG(LogTemp, Error, TEXT("LogicMods bootstrap Blueprint contains compile errors"));
        return 7;
    }

    FClassProperty* WidgetClassProperty = FindFProperty<FClassProperty>(
        Bootstrap->GeneratedClass,
        BootstrapWidgetClassProperty);
    UObject* BootstrapDefaultObject = Bootstrap->GeneratedClass->GetDefaultObject();
    if (WidgetClassProperty == nullptr || BootstrapDefaultObject == nullptr || Blueprint->GeneratedClass == nullptr)
    {
        UE_LOG(LogTemp, Error, TEXT("LogicMods bootstrap class reference property is unavailable"));
        return 8;
    }
    BootstrapDefaultObject->Modify();
    void* WidgetClassValue = WidgetClassProperty->ContainerPtrToValuePtr<void>(BootstrapDefaultObject);
    WidgetClassProperty->SetObjectPropertyValue(WidgetClassValue, Blueprint->GeneratedClass);

    BootstrapPackage->MarkPackageDirty();
    const FString BootstrapFilename = FPackageName::LongPackageNameToFilename(
        BootstrapPackageName,
        FPackageName::GetAssetPackageExtension());
    if (!UPackage::SavePackage(BootstrapPackage, Bootstrap, *BootstrapFilename, SaveArgs))
    {
        UE_LOG(LogTemp, Error, TEXT("Failed to save %s"), *BootstrapFilename);
        return 9;
    }

    UE_LOG(LogTemp, Display, TEXT("PALSKILLDPS_UI_GENERATED %s bootstrap=%s"), *Filename, *BootstrapFilename);
    return 0;
}
