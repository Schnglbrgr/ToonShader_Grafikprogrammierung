Shader "Custom/Toon"
{
    Properties
    {
        [MainTexture] _BaseMap("Base Map", 2D) = "white" {}

        [Header(___Base Colors___)][Space(5)]
        [MainColor] _BaseColor("Base Color", Color) = (1, 1, 1, 1)
        _AmbientColor ("Ambient Color", Color) = (0.35, 0.35, 0.45, 0)

        [Header(___Outline___)][Space(5)]
        [HDR]_OutlineColor ("Outline Color", Color) = (0, 0, 0, 1)
        _OutlineThickness ("Outline Thickness", Range(0, 0.05)) = 0.02

        [Header(___CelShading___)][Space(5)]
        _ShadowTexture("Shadow Texture", 2D) = "white" {}
        _LightThreshold("Light Threshold", Range(0.001, 1)) = 0.001
        _Steps ("Steps", Range(2,10)) = 2

        [Header(___Specular___)][Space(5)]
        _SpecularPower ("Specular Power", Range(1, 100)) = 50
        _SpecularIntensity ("Specular Intensity", Range(1, 100)) = 2

        [Header(___Rim Light___)][Space(5)]
        [HDR] _RimLightColor("Rim Light Color", Color) = (1, 1, 1, 1)
        _RimLightThreshold ("Rim Light Threshold", Range(0.01, 1)) = 0.7
        _RimLightIntensity ("Rim Light Intensity", Range(1, 100)) = 3
    }



    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" }


        Pass
        {
            Name "ToonShading"
            Tags {"LightMode" = "UniversalForward"}

            Cull Off

        
            HLSLPROGRAM

            #pragma vertex vert
            #pragma fragment frag

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT _SHADOWS_SOFT_LOW _SHADOWS_SOFT_MEDIUM _SHADOWS_SOFT_HIGH
            

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"


            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionHCS  : SV_POSITION;
                float2 uv           : TEXCOORD0;
                float3 normalWS     : TEXCOORD1;
                float3 viewDirWS    : TEXCOORD2;
                float3 posWS        : TEXCOORD3;
            };


            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);
            TEXTURE2D(_ShadowTexture);
            SAMPLER(sampler_ShadowTexture);

            CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            float4 _ShadowTexture_ST;
            float _LightThreshold;

            float4 _BaseColor;
            float4 _AmbientColor;
            float4 _OutlineColor;
            float _Steps;
            float _SpecularPower;
            float _SpecularIntensity;
            float _RimLightThreshold;
            float _RimLightIntensity;
            float4 _RimLightColor;
            CBUFFER_END

            Varyings vert(Attributes IN)
            {
                Varyings OUT;

                float3 posWS = TransformObjectToWorld(IN.positionOS.xyz);
                OUT.posWS = posWS;
                OUT.positionHCS = TransformWorldToHClip(posWS);
                OUT.uv = TRANSFORM_TEX(IN.uv, _BaseMap);
                OUT.normalWS = normalize(TransformObjectToWorldNormal(IN.normalOS));
                OUT.viewDirWS = normalize(GetCameraPositionWS() - posWS);

                return OUT;
            }


            struct CelShadingVariables
            {
                float specularPower;
                float specularIntensity;
                float rimThreshold;
                float3 ambientColor;
                float rimLightIntensity;
                float3 rimLightColor;
            };

            CelShadingVariables GetCelShadingVariables()
            {
                CelShadingVariables v;
                v.specularPower = _SpecularPower;
                v.specularIntensity = _SpecularIntensity;
                v.rimThreshold = _RimLightThreshold;
                v.ambientColor = _AmbientColor.xyz;
                v.rimLightIntensity = _RimLightIntensity;
                v.rimLightColor = _RimLightColor.rgb;
                return v;
            }


            float3 CalculateCelShading(float3 n, Light l, float3 viewDir, CelShadingVariables v, float shadowAttenuation, float2 uv)
            {
                float3 baseTex = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv).rgb;
                float2 shadowUV = TRANSFORM_TEX(uv, _ShadowTexture);
                float4 shadowTex = SAMPLE_TEXTURE2D(_ShadowTexture, sampler_ShadowTexture, shadowUV);

                float3 ambient = _BaseColor.xyz * v.ambientColor.xyz;

                float diffuse = saturate(dot(n, l.direction));

                //----Receive Shadow---
                float litColor = saturate(diffuse * shadowAttenuation);

                float lightMask = step(_LightThreshold, litColor);
                float lightRamp = saturate((litColor - _LightThreshold) / (1.0 - _LightThreshold));
                
                float3 color = baseTex * lerp(1.0, shadowTex, shadowTex.a * (1.0 - lightMask));


                //----Specular----
                float3 h = normalize(l.direction + viewDir);
                float specular = saturate(dot(n, h));
                specular = pow(specular, v.specularPower);
                specular *= lightRamp;
                float specularStep = (floor(specular * 2) / 2) * v.specularIntensity;

                lightRamp = floor(lightRamp * _Steps) / _Steps;
                lightRamp *= lightMask;
                
                //----Rimlight----
                float3 rim = saturate(1.0 - dot(viewDir, n));
                rim = step(v.rimThreshold, rim);
                rim *= lightRamp;
                rim *= v.rimLightIntensity * v.rimLightColor;

                float3 lit = color * lightRamp;
                float3 highlights = max(specularStep, rim);

                return l.color * (lit + highlights) + ambient * color;
            }




            half4 frag(Varyings IN) : SV_Target
            {
                Light mainLight = GetMainLight(TransformWorldToShadowCoord(IN.posWS));
                float shadowAtten = saturate(mainLight.shadowAttenuation);
                shadowAtten = step(0.5, shadowAtten);

                CelShadingVariables c = GetCelShadingVariables();

                float3 N = normalize(IN.normalWS);
                float3 V = normalize(IN.viewDirWS);

                float3 lighting = CalculateCelShading(N, mainLight, V, c, shadowAtten, IN.uv);

                return float4 (lighting, 1);
            }
            ENDHLSL
        }


        
        Pass
        {
            Name "Outline"
            Cull Front
            ZWrite On
            ZTest LEqual


            HLSLPROGRAM

            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
            };


            CBUFFER_START(UnityPerMaterial)
                float _OutlineThickness;
                half4 _OutlineColor;
            CBUFFER_END



            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                float3 posWS = TransformObjectToWorld(IN.positionOS.xyz);
                float3 normalWS = TransformObjectToWorldNormal(IN.normalOS);

                float3 posVS = TransformWorldToView(posWS);
                float3 normalVS = TransformWorldToViewDir(normalWS);

                posVS += normalize(normalVS) * _OutlineThickness;
                OUT.positionHCS = mul(UNITY_MATRIX_P, float4(posVS, 1.0));
                return OUT;
                
            }



            half4 frag(Varyings IN) : SV_Target
            {
                return _OutlineColor;
            }
            ENDHLSL
        }
        

        
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }

            ZWrite On
            ZTest LEqual
            Cull Back

            HLSLPROGRAM

            #pragma vertex vert
            #pragma fragment frag

            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };

           Varyings vert(Attributes IN)
            {
                Varyings OUT;

                float3 positionWS = TransformObjectToWorld(IN.positionOS.xyz);
                float3 normalWS   = TransformObjectToWorldNormal(IN.normalOS);
                float3 lightDirWS = GetMainLight().direction;

                OUT.positionCS = TransformWorldToHClip(ApplyShadowBias(positionWS, normalWS, lightDirWS));

                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                return 0;
            }

            ENDHLSL
        }
    }
}
